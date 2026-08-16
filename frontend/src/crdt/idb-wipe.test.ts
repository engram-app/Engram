import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { forgetCrdtDbs, knownCrdtDbs, rememberCrdtDb } from "./idb-registry";
import { wipeCrdtIndexedDb } from "./idb-wipe";
import { CRDT_IDB_PREFIX } from "./manager";
import { QUEUE_DB_NAME } from "./op-queue-persist";

/** Collects deleteDatabase calls; every request succeeds on the first attempt. */
function stubIndexedDb(opts: { enumerate?: string[] | null }): string[] {
	const deleted: string[] = [];
	const base: Record<string, unknown> = {
		deleteDatabase: (name: string) => {
			deleted.push(name);
			const req: Record<string, unknown> = {};
			queueMicrotask(() => (req.onsuccess as () => void)?.());
			return req;
		},
	};
	// `enumerate: null` models Firefox <126 / older Safari: indexedDB exists,
	// indexedDB.databases does not.
	if (opts.enumerate !== null) {
		base.databases = async () => (opts.enumerate ?? []).map((name) => ({ name }));
	}
	vi.stubGlobal("indexedDB", base);
	return deleted;
}

describe("wipeCrdtIndexedDb", () => {
	beforeEach(() => {
		forgetCrdtDbs();
	});

	afterEach(() => {
		vi.unstubAllGlobals();
		vi.useRealTimers();
		forgetCrdtDbs();
	});

	it("deletes every DB with the engram-crdt/ prefix and nothing else", async () => {
		const deleted: string[] = [];
		vi.stubGlobal("indexedDB", {
			databases: async () => [
				{ name: `${CRDT_IDB_PREFIX}v1/notes/a.md` },
				{ name: `${CRDT_IDB_PREFIX}v2/notes/b.md` },
				{ name: "clerk-telemetry" },
				{ name: undefined },
			],
			deleteDatabase: (name: string) => {
				deleted.push(name);
				const req: Record<string, unknown> = {};
				queueMicrotask(() => (req.onsuccess as () => void)?.());
				return req;
			},
		});
		await wipeCrdtIndexedDb();
		// The queue DB is always in the set — it is named, not discovered, because
		// its name falls outside the prefix this sweep matches.
		expect(deleted.sort()).toEqual(
			[`${CRDT_IDB_PREFIX}v1/notes/a.md`, `${CRDT_IDB_PREFIX}v2/notes/b.md`, QUEUE_DB_NAME].sort(),
		);
	});

	// #873. This used to assert a NO-OP, which was the bug: on Firefox <126 the
	// logout wipe found nothing to iterate and silently left every CRDT database
	// — i.e. plaintext note content — on disk for the next user of the machine.
	// The registry is the only source of names there.
	it("deletes registry-known DBs when indexedDB.databases is unavailable", async () => {
		const a = `${CRDT_IDB_PREFIX}v1/note-a`;
		const b = `${CRDT_IDB_PREFIX}v1/note-b`;
		rememberCrdtDb(a);
		rememberCrdtDb(b);

		const deleted = stubIndexedDb({ enumerate: null });
		await wipeCrdtIndexedDb();

		expect(deleted.sort()).toEqual([a, b, QUEUE_DB_NAME].sort());
	});

	// Neither source is complete on its own: enumeration sees docs written by a
	// build that predates the registry (or by another tab), the registry sees
	// what this tab created. Union, don't choose.
	it("unions enumeration with the registry, without double-deleting", async () => {
		const onlyEnumerated = `${CRDT_IDB_PREFIX}legacy/from-old-build`;
		const onlyRemembered = `${CRDT_IDB_PREFIX}v1/only-in-registry`;
		const both = `${CRDT_IDB_PREFIX}v1/in-both`;

		rememberCrdtDb(onlyRemembered);
		rememberCrdtDb(both);

		const deleted = stubIndexedDb({ enumerate: [onlyEnumerated, both, "clerk-telemetry"] });
		await wipeCrdtIndexedDb();

		expect(deleted.sort()).toEqual([onlyEnumerated, onlyRemembered, both, QUEUE_DB_NAME].sort());
		// "clerk-telemetry" is same-origin but not ours.
		expect(deleted).not.toContain("clerk-telemetry");
		// Exactly once each, despite `both` appearing in two sources.
		expect(new Set(deleted).size).toBe(deleted.length);
	});

	it("clears the registry once the deletes have settled", async () => {
		rememberCrdtDb(`${CRDT_IDB_PREFIX}v1/note-a`);
		stubIndexedDb({ enumerate: [] });

		expect(knownCrdtDbs()).toHaveLength(1);
		await wipeCrdtIndexedDb();
		expect(knownCrdtDbs()).toEqual([]);
	});

	it("still resolves when there is nothing to delete at all", async () => {
		stubIndexedDb({ enumerate: [] });
		await expect(wipeCrdtIndexedDb()).resolves.toBeUndefined();
	});

	// rememberCrdtDb runs on EVERY doc open. Without the write-through cache it
	// re-read, re-parsed, linear-scanned and re-serialised the whole registry
	// each time — O(n²) across a vault, with a synchronous main-thread write per
	// open. Storage must be touched once per NAME, not once per call.
	it("does not touch storage when re-remembering a known name", () => {
		const setItem = vi.spyOn(globalThis.localStorage, "setItem");
		const name = `${CRDT_IDB_PREFIX}v1/hot-note`;

		rememberCrdtDb(name);
		const afterFirst = setItem.mock.calls.length;
		expect(afterFirst).toBeGreaterThan(0);

		for (let i = 0; i < 50; i++) {
			rememberCrdtDb(name);
		}

		expect(setItem.mock.calls.length).toBe(afterFirst);
		expect(knownCrdtDbs()).toEqual([name]);
		setItem.mockRestore();
	});

	it("no-ops when indexedDB itself is absent", async () => {
		rememberCrdtDb(`${CRDT_IDB_PREFIX}v1/note-a`);
		vi.stubGlobal("indexedDB", undefined);
		await expect(wipeCrdtIndexedDb()).resolves.toBeUndefined();
		// Registry survives — the databases are still there to delete later.
		expect(knownCrdtDbs()).toHaveLength(1);
	});

	it("retries after onblocked and resolves when the second attempt succeeds", async () => {
		vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });

		const attempts: string[] = [];
		const DB_NAME = `${CRDT_IDB_PREFIX}vault/note.md`;

		vi.stubGlobal("indexedDB", {
			databases: async () => [{ name: DB_NAME }],
			deleteDatabase: (name: string) => {
				attempts.push(name);
				const req: Record<string, unknown> = {};
				// Keyed on the NAME, not the call index: the wipe deletes the
				// op-queue database in the same pass, so "first call" is no longer
				// this database.
				const firstTryOfTarget =
					name === DB_NAME && attempts.filter((n) => n === DB_NAME).length === 1;
				if (firstTryOfTarget) {
					queueMicrotask(() => (req.onblocked as () => void)?.());
				} else {
					queueMicrotask(() => (req.onsuccess as () => void)?.());
				}
				return req;
			},
		});

		const wipePromise = wipeCrdtIndexedDb();
		// Flush microtasks so the first deleteDatabase's queueMicrotask fires onblocked
		await Promise.resolve();
		await Promise.resolve();
		// Advance past the 300 ms retry delay so the setTimeout fires
		await vi.advanceTimersByTimeAsync(300);
		// Flush microtasks so the second deleteDatabase's queueMicrotask fires onsuccess
		await Promise.resolve();
		await Promise.resolve();

		await wipePromise;

		// Twice for the blocked target, once for the queue DB alongside it.
		expect(attempts.filter((n) => n === DB_NAME)).toEqual([DB_NAME, DB_NAME]);
		expect(attempts).toContain(QUEUE_DB_NAME);
	});
});

describe("the durable op-queue is wiped too", () => {
	// It is named "engram-crdt-queue" — one character outside the
	// "engram-crdt/" prefix the enumeration sweep matches on, so it was never
	// deleted. Its entries carry note paths (create ops store `{ path }`), so
	// on a shared machine a note path outlived the sign-out meant to clear it.
	it("deletes the queue database even though it is outside CRDT_IDB_PREFIX", async () => {
		const deleted = stubIndexedDb({ enumerate: [] });

		await wipeCrdtIndexedDb();

		expect(deleted).toContain(QUEUE_DB_NAME);
	});

	// Firefox <126 / older Safari: no enumeration, so the name has to come from
	// somewhere that does not depend on the browser.
	it("still deletes it when the browser cannot enumerate databases", async () => {
		const deleted = stubIndexedDb({ enumerate: null });

		await wipeCrdtIndexedDb();

		expect(deleted).toContain(QUEUE_DB_NAME);
	});
});
