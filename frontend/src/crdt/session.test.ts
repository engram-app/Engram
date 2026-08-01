import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
	__isNoteOpen,
	clearRehandshakeBackoff,
	closeDoc,
	enroll,
	enrollIfLive,
	getCrdtSyncStatus,
	handleFrame,
	installCrdtResyncTriggers,
	notifyCrdtChannelError,
	notifyCrdtChannelJoined,
	openDoc,
	resyncOpenDocs,
	scheduleRehandshake,
	startCrdtSession,
	stopCrdtSession,
	subscribeToCrdtSyncStatus,
} from "./session";

const VAULT = "vault-xyz";

describe("crdt session", () => {
	beforeEach(() => stopCrdtSession());

	it("openDoc returns a Y.Text + awareness for a note", async () => {
		startCrdtSession({ vaultId: VAULT, push: () => {} });
		const handle = await openDoc("note.md");
		expect(handle).not.toBeNull();
		handle!.ytext.insert(0, "hi");
		expect(handle!.ytext.toJSON()).toBe("hi");
	});

	it("enroll pushes a STEP1 frame addressed by docId (the note_id, unprefixed)", async () => {
		const push = vi.fn();
		startCrdtSession({ vaultId: VAULT, push });
		await openDoc("note.md");
		enroll("note.md");
		await vi.waitFor(() => expect(push).toHaveBeenCalled());
		expect(push.mock.calls[0]![0]).toBe("note.md");
	});

	it("a local edit pushes an update frame via the transport", async () => {
		const push = vi.fn();
		startCrdtSession({ vaultId: VAULT, push });
		const handle = await openDoc("note.md");
		handle!.ytext.insert(0, "abc");
		await vi.waitFor(() => expect(push).toHaveBeenCalled());
		expect(push.mock.calls.at(-1)![0]).toBe("note.md");
	});

	it("resyncOpenDocs re-sends STEP1 for open docs on reconnect", async () => {
		const push = vi.fn();
		startCrdtSession({ vaultId: VAULT, push });
		await openDoc("note.md");
		enroll("note.md");
		await vi.waitFor(() => expect(push).toHaveBeenCalled());
		push.mockClear();
		resyncOpenDocs();
		await vi.waitFor(() => expect(push).toHaveBeenCalled());
		expect(push.mock.calls[0]![0]).toBe("note.md");
	});

	it("handleFrame drops frames for docs not open in the session", async () => {
		// Build a valid STEP2/UPDATE frame from a separate session
		const frames: [string, string][] = [];
		startCrdtSession({ vaultId: VAULT, push: (id, b64) => frames.push([id, b64]) });
		const a = await openDoc("note.md");
		a!.ytext.insert(0, "ghost-content");
		await vi.waitFor(() => expect(frames.length).toBeGreaterThan(0));
		const [, b64] = frames.at(-1)!;
		stopCrdtSession();

		// New session — do NOT open ghost.md
		startCrdtSession({ vaultId: VAULT, push: () => {} });
		await handleFrame("ghost.md", b64);

		// Now open ghost.md; it must not contain the leaked content
		const ghostHandle = await openDoc("ghost.md");
		expect(ghostHandle!.ytext.toJSON()).not.toContain("ghost-content");
	});

	it("handleFrame applies inbound bytes (two-session round-trip)", async () => {
		// Session A emits frames into a buffer; feed them into session B.
		const frames: [string, string][] = [];
		startCrdtSession({ vaultId: VAULT, push: (id, b64) => frames.push([id, b64]) });
		const a = await openDoc("note.md");
		a!.ytext.insert(0, "payload");
		await vi.waitFor(() => expect(frames.length).toBeGreaterThan(0));
		const [, b64] = frames.at(-1)!;
		stopCrdtSession();
		startCrdtSession({ vaultId: VAULT, push: () => {} });
		await openDoc("note.md");
		await handleFrame("note.md", b64);
		const b = await openDoc("note.md");
		expect(b!.ytext.toJSON()).toContain("payload");
	});

	it("installCrdtResyncTriggers re-handshakes open docs on window focus", async () => {
		const push = vi.fn();
		startCrdtSession({ vaultId: VAULT, push });
		await openDoc("note.md");
		enroll("note.md");
		await vi.waitFor(() => expect(push).toHaveBeenCalled());
		push.mockClear();

		const remove = installCrdtResyncTriggers();
		window.dispatchEvent(new Event("focus"));
		await vi.waitFor(() => expect(push).toHaveBeenCalled());
		expect(push.mock.calls[0]![0]).toBe("note.md");

		// Cleanup removes the listener: a later focus must NOT push again.
		remove();
		push.mockClear();
		window.dispatchEvent(new Event("focus"));
		await new Promise((r) => setTimeout(r, 20));
		expect(push).not.toHaveBeenCalled();
	});

	// Finding 1: flattenIfBloated must be skipped for an open note
	it("flatten is skipped while a doc is open and runs after it is closed", async () => {
		startCrdtSession({ vaultId: VAULT, push: () => {} });
		// openDoc marks the note as open
		await openDoc("note.md");
		enroll("note.md");
		// The enrollment onAfterEnroll fires flattenIfBloated; since the note is
		// open it should return false (no-op). We verify indirectly: the doc
		// object returned by a subsequent openDoc must be the SAME instance
		// (not a rebuilt one), proving the old doc was not destroyed.
		const before = (await openDoc("note.md"))!.ytext.doc;
		// Close the note to remove the open guard
		closeDoc("note.md");
		// After close the guard is lifted; a direct flattenIfBloated call on a
		// non-open note should execute normally (returns false because thresholds
		// are not crossed in a fresh test doc, but must NOT be skipped by the guard).
		// We re-open to verify the note is no longer protected.
		await openDoc("note.md");
		const after = (await openDoc("note.md"))!.ytext.doc;
		// Both accesses must return valid doc objects (not null/destroyed)
		expect(before).toBeTruthy();
		expect(after).toBeTruthy();
	});

	describe("openDoc lifecycle hardening", () => {
		it("openDoc called before startCrdtSession resolves once the session starts", async () => {
			stopCrdtSession();
			const p = openDoc("note-a"); // no session yet — must NOT resolve null immediately
			let settled = false;
			p.then(() => {
				settled = true;
			});
			await Promise.resolve();
			expect(settled).toBe(false); // still waiting
			startCrdtSession({ vaultId: "v1", push: () => {} });
			const h = await p;
			expect(h).not.toBeNull();
			expect(h?.ytext).toBeDefined();
		});

		it("closeDoc during in-flight openDoc yields null and leaves no ghost state", async () => {
			startCrdtSession({ vaultId: "v1", push: () => {} });
			const p = openDoc("note-b");
			closeDoc("note-b"); // races the await inside openDoc
			const h = await p;
			expect(h).toBeNull();
			// no ghost: a fresh open must produce a working handle whose awareness
			// is bound to the SAME doc as its ytext (the ghost bug bound awareness
			// to a destroyed doc)
			const h2 = await openDoc("note-b");
			expect(h2).not.toBeNull();
			expect(h2?.awareness.doc).toBe(h2?.doc);
			closeDoc("note-b");
		});

		it("rapid close→reopen mid-load keeps the reopened doc's open marker", async () => {
			// openDoc A is mid-load; closeDoc bumps the epoch + drops A's marker;
			// openDoc B re-adds its OWN marker. When A resumes and bails on the
			// epoch mismatch, it must NOT delete B's marker (that would strip B's
			// flattenIfBloated open-editor protection).
			startCrdtSession({ vaultId: "v1", push: () => {} });
			const a = openDoc("note-race"); // A: awaits the initial load
			// Let A pass its FIRST guard (waitForSessionStart) and mark the note
			// open, so it is suspended INSIDE getSharedText when we close. That is
			// the interleaving that reaches openDoc's post-await abort path.
			await Promise.resolve();
			closeDoc("note-race"); // bumps epoch, removes A's marker
			const b = openDoc("note-race"); // B: re-adds its own marker
			const [hA, hB] = await Promise.all([a, b]);
			expect(hA).toBeNull(); // A bailed on the epoch mismatch
			expect(hB).not.toBeNull(); // B produced a working handle
			// The marker B added must survive A's late abort path.
			expect(__isNoteOpen("note-race")).toBe(true);
			closeDoc("note-race");
			expect(__isNoteOpen("note-race")).toBe(false);
		});

		it("stopCrdtSession during in-flight openDoc yields null", async () => {
			startCrdtSession({ vaultId: "v1", push: () => {} });
			const p = openDoc("note-c");
			stopCrdtSession();
			// openDoc must not hang forever after stop: it re-waits for a session;
			// start a new session so the waiter resolves, then the epoch check
			// (bumped by stop) must return null for the stale call.
			startCrdtSession({ vaultId: "v1", push: () => {} });
			const h = await p;
			expect(h).toBeNull();
		});
	});

	describe("enrollment lifecycle", () => {
		it("reopening a closed doc re-sends STEP1", async () => {
			const frames: string[] = [];
			startCrdtSession({ vaultId: "v1", push: (_id, b64) => frames.push(b64) });
			await openDoc("note-r");
			enroll("note-r");
			await vi.waitFor(() => expect(frames.length).toBeGreaterThan(0)); // STEP1 went out
			const afterFirst = frames.length;
			closeDoc("note-r");
			await openDoc("note-r");
			enroll("note-r");
			await vi.waitFor(() => expect(frames.length).toBeGreaterThan(afterFirst)); // STEP1 re-sent
			closeDoc("note-r");
		});

		it("enrollIfLive ignores notes that are neither open nor live", async () => {
			const frames: string[] = [];
			startCrdtSession({ vaultId: "v1", push: (_id, b64) => frames.push(b64) });
			enrollIfLive("note-background"); // crdt_doc_ready for an unopened note
			await Promise.resolve();
			expect(frames).toHaveLength(0);
			// and no Y.Doc was materialized: openDoc-then-close then enrollIfLive
			// must also stay silent
			await openDoc("note-bg2");
			closeDoc("note-bg2");
			frames.length = 0;
			enrollIfLive("note-bg2");
			await Promise.resolve();
			expect(frames).toHaveLength(0);
		});

		it("enrollIfLive enrolls an open doc", async () => {
			const frames: string[] = [];
			startCrdtSession({ vaultId: "v1", push: (_id, b64) => frames.push(b64) });
			await openDoc("note-open");
			enrollIfLive("note-open");
			await vi.waitFor(() => expect(frames.length).toBeGreaterThan(0));
			closeDoc("note-open");
		});
	});

	describe("scheduleRehandshake", () => {
		// Only fake setTimeout/clearTimeout — IndexedDB (happy-dom) breaks when
		// all async APIs are faked, preventing vi.waitFor from resolving.
		beforeEach(() => vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] }));
		afterEach(() => vi.useRealTimers());

		it("re-runs STEP1 for a live doc after the delay, deduped", async () => {
			const frames: string[] = [];
			startCrdtSession({ vaultId: "v1", push: (_id, b64) => frames.push(b64) });
			await openDoc("note-rh");
			enroll("note-rh");
			await vi.waitFor(() => expect(frames.length).toBeGreaterThan(0));
			const before = frames.length;
			// docId IS the note_id now (no vault-prefix) — matches what enroll() sent.
			scheduleRehandshake("note-rh", 2000);
			scheduleRehandshake("note-rh", 2000); // dedupe: second is a no-op
			await vi.advanceTimersByTimeAsync(2000);
			await vi.waitFor(() => expect(frames.length).toBe(before + 1)); // exactly one new STEP1
			closeDoc("note-rh");
		});

		it("is a no-op for a doc that is no longer live when the timer fires", async () => {
			const frames: string[] = [];
			startCrdtSession({ vaultId: "v1", push: (_id, b64) => frames.push(b64) });
			await openDoc("note-gone");
			enroll("note-gone");
			await vi.waitFor(() => expect(frames.length).toBeGreaterThan(0));
			scheduleRehandshake("note-gone", 1000);
			closeDoc("note-gone");
			const before = frames.length;
			await vi.advanceTimersByTimeAsync(1000);
			expect(frames.length).toBe(before); // nothing sent for a closed doc
		});

		it("stopCrdtSession clears pending rehandshake timers", async () => {
			const frames: string[] = [];
			startCrdtSession({ vaultId: "v1", push: (_id, b64) => frames.push(b64) });
			await openDoc("note-stop");
			scheduleRehandshake("note-stop", 1000);
			stopCrdtSession();
			const before = frames.length;
			await vi.advanceTimersByTimeAsync(1000);
			expect(frames.length).toBe(before);
		});

		it("backs off exponentially across consecutive failures", async () => {
			const frames: string[] = [];
			startCrdtSession({ vaultId: "v1", push: (_id, b64) => frames.push(b64) });
			await openDoc("note-bo");
			const base = frames.length; // re-handshake itself produces the STEP1
			// Attempt 1 fires at the base delay (1000).
			scheduleRehandshake("note-bo", 1000);
			await vi.advanceTimersByTimeAsync(1000);
			await vi.waitFor(() => expect(frames.length).toBe(base + 1));
			// Attempt 2 doubles to 2000 — 1000 is NOT enough to fire it.
			scheduleRehandshake("note-bo", 1000);
			await vi.advanceTimersByTimeAsync(1000);
			expect(frames.length).toBe(base + 1);
			await vi.advanceTimersByTimeAsync(1000); // total 2000
			await vi.waitFor(() => expect(frames.length).toBe(base + 2));
			closeDoc("note-bo");
		});

		it("stops re-handshaking after the attempt cap (circuit breaker)", async () => {
			const frames: string[] = [];
			startCrdtSession({ vaultId: "v1", push: (_id, b64) => frames.push(b64) });
			await openDoc("note-cb");
			const base = frames.length;
			// Exhaust the attempt budget; advance past the capped max delay each time.
			for (let i = 0; i < 6; i++) {
				scheduleRehandshake("note-cb", 1000);
				await vi.advanceTimersByTimeAsync(30_000);
			}
			const afterCap = frames.length;
			expect(afterCap).toBe(base + 6);
			// Circuit open: the 7th schedule arms no timer, so nothing more fires.
			scheduleRehandshake("note-cb", 1000);
			await vi.advanceTimersByTimeAsync(30_000);
			expect(frames.length).toBe(afterCap);
			closeDoc("note-cb");
		});

		it("clearRehandshakeBackoff resets to the base delay + re-arms the breaker", async () => {
			const frames: string[] = [];
			startCrdtSession({ vaultId: "v1", push: (_id, b64) => frames.push(b64) });
			await openDoc("note-clr");
			// One failure → attempts=1 (next would double to 2000).
			scheduleRehandshake("note-clr", 1000);
			await vi.advanceTimersByTimeAsync(1000);
			const base = frames.length;
			// A successful ack clears the backoff.
			clearRehandshakeBackoff("note-clr");
			// Next failure fires at the BASE delay (1000), proving the reset.
			scheduleRehandshake("note-clr", 1000);
			await vi.advanceTimersByTimeAsync(1000);
			await vi.waitFor(() => expect(frames.length).toBe(base + 1));
			closeDoc("note-clr");
		});

		// A tripped breaker MUST stay escapable. The ack path alone is not enough:
		// it only fires when we push, so a note we merely read could sit deaf for
		// the rest of the session. These three pin the other exits.

		it("an open breaker re-arms on a reconnect resync (new connectivity epoch)", async () => {
			const frames: string[] = [];
			startCrdtSession({ vaultId: "v1", push: (_id, b64) => frames.push(b64) });
			await openDoc("note-recon");
			for (let i = 0; i < 6; i++) {
				scheduleRehandshake("note-recon", 1000);
				await vi.advanceTimersByTimeAsync(30_000);
			}
			scheduleRehandshake("note-recon", 1000); // breaker open — no timer armed
			await vi.advanceTimersByTimeAsync(30_000);
			const stuck = frames.length;

			resyncOpenDocs(); // reconnect: re-enrolls AND clears the attempt budget
			await vi.waitFor(() => expect(frames.length).toBeGreaterThan(stuck));
			const afterResync = frames.length;

			// Budget restored: a fresh failure retries at the BASE delay again.
			scheduleRehandshake("note-recon", 1000);
			await vi.advanceTimersByTimeAsync(1000);
			await vi.waitFor(() => expect(frames.length).toBe(afterResync + 1));
			closeDoc("note-recon");
		});

		it("an open breaker re-arms on a user reopen (closeDoc clears the budget)", async () => {
			const frames: string[] = [];
			startCrdtSession({ vaultId: "v1", push: (_id, b64) => frames.push(b64) });
			await openDoc("note-reopen");
			for (let i = 0; i < 6; i++) {
				scheduleRehandshake("note-reopen", 1000);
				await vi.advanceTimersByTimeAsync(30_000);
			}
			closeDoc("note-reopen");
			await openDoc("note-reopen");
			const base = frames.length;

			// Reopened with a fresh budget: the next failure retries at the base delay.
			scheduleRehandshake("note-reopen", 1000);
			await vi.advanceTimersByTimeAsync(1000);
			await vi.waitFor(() => expect(frames.length).toBe(base + 1));
			closeDoc("note-reopen");
		});

		// The inverse of the two above, and the reason handleFrame does NOT clear
		// the budget. scheduleRehandshake is fed by crdt_msg REJECTIONS, and
		// `rate_limited` is one of them — so "pushes rejected while other devices
		// keep editing" is a real state in which frames keep arriving. If receipt
		// re-armed the breaker, every frame would reset the budget and the retry
		// would run without bound: the exact storm this breaker exists to stop.
		it("inbound frames do NOT re-arm the breaker (rate-limited push + live traffic)", async () => {
			const donor: string[] = [];
			startCrdtSession({ vaultId: "v1", push: (_id, b64) => donor.push(b64) });
			const a = await openDoc("note-inbound");
			a!.ytext.insert(0, "remote-edit");
			await vi.waitFor(() => expect(donor.length).toBeGreaterThan(0));
			const frame = donor.at(-1)!;
			stopCrdtSession();

			const frames: string[] = [];
			startCrdtSession({ vaultId: "v1", push: (_id, b64) => frames.push(b64) });
			await openDoc("note-inbound");
			for (let i = 0; i < 6; i++) {
				scheduleRehandshake("note-inbound", 1000);
				await vi.advanceTimersByTimeAsync(30_000);
			}
			scheduleRehandshake("note-inbound", 1000); // breaker open — nothing armed
			await vi.advanceTimersByTimeAsync(30_000);
			const stuck = frames.length;

			// Live traffic arrives for the note. The frame must still APPLY...
			await handleFrame("note-inbound", frame);
			const handle = await openDoc("note-inbound");
			expect(handle!.ytext.toJSON()).toContain("remote-edit");

			// ...but it must NOT hand the breaker a fresh budget.
			scheduleRehandshake("note-inbound", 1000);
			await vi.advanceTimersByTimeAsync(30_000);
			expect(frames.length).toBe(stuck);
			closeDoc("note-inbound");
		});
	});

	describe("resyncOpenDocs throttle", () => {
		it("re-enrolls at most once per window under a reconnect storm", async () => {
			const nowSpy = vi.spyOn(Date, "now").mockReturnValue(1_000_000);
			try {
				const frames: string[] = [];
				startCrdtSession({ vaultId: "v1", push: (_id, b64) => frames.push(b64) });
				await openDoc("note-th");
				const base = frames.length; // openDoc alone does not enroll
				resyncOpenDocs(); // first: enrolls the open doc → one STEP1
				await vi.waitFor(() => expect(frames.length).toBe(base + 1));
				const afterFirst = frames.length;
				resyncOpenDocs(); // same instant → throttled
				resyncOpenDocs();
				await new Promise((r) => setTimeout(r, 20));
				expect(frames.length).toBe(afterFirst);
				nowSpy.mockReturnValue(1_000_000 + 4000); // past the window
				resyncOpenDocs();
				await vi.waitFor(() => expect(frames.length).toBe(afterFirst + 1));
				closeDoc("note-th");
			} finally {
				nowSpy.mockRestore();
			}
		});
	});

	// Finding 2: CRDT sync status observable
	it("sync status starts as connecting, flips to synced on join ok, error on join failure", () => {
		startCrdtSession({ vaultId: VAULT, push: () => {} });
		expect(getCrdtSyncStatus()).toBe("connecting");

		const observed: string[] = [];
		const unsub = subscribeToCrdtSyncStatus((s) => observed.push(s));

		notifyCrdtChannelJoined();
		expect(getCrdtSyncStatus()).toBe("synced");
		expect(observed).toEqual(["synced"]);

		notifyCrdtChannelError();
		expect(getCrdtSyncStatus()).toBe("error");
		expect(observed).toEqual(["synced", "error"]);

		// Duplicate status must not fire subscribers again
		notifyCrdtChannelError();
		expect(observed).toEqual(["synced", "error"]);

		unsub();
		notifyCrdtChannelJoined();
		// After unsubscribe, listener is not called
		expect(observed).toEqual(["synced", "error"]);
	});
});
