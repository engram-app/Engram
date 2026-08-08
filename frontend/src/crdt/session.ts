import { Awareness } from "y-protocols/awareness";
import type * as Y from "yjs";
import { rlog } from "../observability/remote-log";
import { CrdtChannel } from "./channel";
import { CrdtEnrollment } from "./enrollment";
import { CrdtManager } from "./manager";
import { crdtMark } from "./perf";

interface Session {
	vaultId: string;
	manager: CrdtManager;
	channel: CrdtChannel;
	enrollment: CrdtEnrollment;
	awareness: Map<string, Awareness>;
	/** note_ids currently open in the editor (via openDoc / closeDoc). Used to
	 *  guard flattenIfBloated so a live editor doc is never destroyed. */
	openNoteIds: Set<string>;
}

let session: Session | null = null;

/** Monotonically-increasing counter bumped on every stopCrdtSession call.
 *  openDoc captures it at entry and bails if it changes across any await,
 *  covering notes that are parked in waitForSessionStart when the stop fires. */
let sessionGeneration = 0;

/** Resolvers parked by openDoc calls that arrived before the session started. */
let sessionStartWaiters: Array<() => void> = [];

/** Per-note_id cancellation epochs. Bumped by closeDoc/stopCrdtSession; an
 *  in-flight openDoc captures the epoch at entry and bails (cleaning up any
 *  partial state) if it changed across an await. Module-level so a closeDoc
 *  issued while no session exists still cancels a waiting openDoc. */
const docEpochs = new Map<string, number>();

/** Pending per-note_id rehandshake timers (error/timeout reply recovery). */
const rehandshakeTimers = new Map<string, ReturnType<typeof setTimeout>>();

/** Per-note consecutive re-handshake attempts, for exponential backoff + a
 *  circuit-breaker. Cleared by `clearRehandshakeBackoff` on a successful
 *  crdt_msg ack (connectivity proven for that note) and on teardown. Without a
 *  bound, a persistently-failing handshake re-fired every ~1s forever and,
 *  combined with the reconnect-driven `resyncOpenDocs`, turned any socket
 *  hiccup into a CPU-melting storm. */
const rehandshakeAttempts = new Map<string, number>();
const REHANDSHAKE_MAX_ATTEMPTS = 6;
const REHANDSHAKE_MAX_DELAY_MS = 30_000;

/** Throttle for `resyncOpenDocs`: a reconnect storm fires `socket.onOpen` many
 *  times in seconds, and each call re-enrolls every open doc. One re-sync per
 *  window is enough to recover; the rest is amplification. NEGATIVE_INFINITY so
 *  the first call in a session always passes. */
const RESYNC_MIN_INTERVAL_MS = 3000;
let lastResyncAt = Number.NEGATIVE_INFINITY;

function bumpEpoch(noteId: string): void {
	docEpochs.set(noteId, (docEpochs.get(noteId) ?? 0) + 1);
}

function waitForSessionStart(): Promise<void> {
	if (session) {
		return Promise.resolve();
	}
	return new Promise((resolve) => sessionStartWaiters.push(resolve));
}

let syncStatus: CrdtSyncStatus = "connecting";
const syncStatusListeners = new Set<(s: CrdtSyncStatus) => void>();

function setCrdtSyncStatus(s: CrdtSyncStatus): void {
	if (syncStatus === s) {
		return;
	}
	syncStatus = s;
	for (const cb of syncStatusListeners) {
		cb(s);
	}
}

// ── Sync status ────────────────────────────────────────────────────────────
export type CrdtSyncStatus = "connecting" | "synced" | "error";

export function getCrdtSyncStatus(): CrdtSyncStatus {
	return syncStatus;
}

export function subscribeToCrdtSyncStatus(cb: (s: CrdtSyncStatus) => void): () => void {
	syncStatusListeners.add(cb);
	return () => syncStatusListeners.delete(cb);
}

export interface StartSessionOpts {
	vaultId: string;
	/** Transport out: push a base64 y-protocols frame for docId (a note_id) to
	 *  the server. */
	push: (docId: string, b64: string) => void;
	onPersistError?: (noteId: string, err: unknown) => void;
}

export function startCrdtSession(opts: StartSessionOpts): void {
	stopCrdtSession();
	setCrdtSyncStatus("connecting");
	// Declare channel first so the onUpdate closure can reference it.
	// channel is assigned before any update tick fires.
	let channel: CrdtChannel;
	const manager = new CrdtManager({
		onUpdate: (docId, update) => channel.sendUpdateRaw(docId, update),
		onPersistError: opts.onPersistError,
	});
	channel = new CrdtChannel({ manager, send: opts.push });
	const openNoteIds = new Set<string>();
	const enrollment = new CrdtEnrollment({
		startSync: (id) => channel.startSync(id),
		resetSync: (id) => channel.resetSync(id),
		onAfterEnroll: (id) => {
			// Skip flatten while the doc is open in an editor -- destroying and
			// rebuilding the Y.Doc would leave the editor bound to a dead doc.
			if (openNoteIds.has(id)) {
				return Promise.resolve();
			}
			return manager.flattenIfBloated(id).then(() => undefined);
		},
	});
	session = {
		vaultId: opts.vaultId,
		manager,
		channel,
		enrollment,
		awareness: new Map(),
		openNoteIds,
	};
	const waiters = sessionStartWaiters;
	sessionStartWaiters = [];
	for (const w of waiters) {
		w();
	}
}

export function stopCrdtSession(): void {
	if (!session) {
		return;
	}
	sessionGeneration++;
	for (const id of session.openNoteIds) {
		bumpEpoch(id);
	}
	for (const id of session.awareness.keys()) {
		bumpEpoch(id);
	}
	for (const a of session.awareness.values()) {
		a.destroy();
	}
	for (const t of rehandshakeTimers.values()) {
		clearTimeout(t);
	}
	rehandshakeTimers.clear();
	rehandshakeAttempts.clear();
	lastResyncAt = Number.NEGATIVE_INFINITY;
	session.manager.destroy().catch((e) => console.warn("CRDT session teardown error", e));
	session = null;
}

/** Open (or attach to) the Y.Doc for a note, keyed by its stable note_id.
 *  Markdown-only eligibility is the CALLER's responsibility (note-page.tsx
 *  checks the note's current path before invoking this) — note_id alone
 *  carries no extension information to gate on here. */
export async function openDoc(
	noteId: string,
): Promise<{ ytext: Y.Text; awareness: Awareness; doc: Y.Doc } | null> {
	crdtMark(noteId, "open:start");
	const epoch = docEpochs.get(noteId) ?? 0;
	const gen = sessionGeneration;
	await waitForSessionStart();
	crdtMark(noteId, "open:session-ready");
	const s = session;
	if (!s || sessionGeneration !== gen || (docEpochs.get(noteId) ?? 0) !== epoch) {
		return null; // closed or torn down while waiting
	}
	s.openNoteIds.add(noteId);
	const ytext = await s.manager.getSharedText(noteId);
	if (session !== s || sessionGeneration !== gen || (docEpochs.get(noteId) ?? 0) !== epoch) {
		// closeDoc/stop ran during the await. Do NOT delete the open marker: an
		// epoch bump means closeDoc already removed it (or the session is dead),
		// and a same-note reopen (openDoc B) may have re-added its OWN marker in
		// between — deleting here would strip B's flattenIfBloated protection.
		return null;
	}
	let awareness = s.awareness.get(noteId);
	if (!awareness) {
		awareness = new Awareness(ytext.doc!);
		s.awareness.set(noteId, awareness);
	}
	crdtMark(noteId, "open:resolved");
	return { ytext, awareness, doc: ytext.doc! };
}

export function closeDoc(noteId: string): void {
	bumpEpoch(noteId);
	if (!session) {
		return;
	}
	session.openNoteIds.delete(noteId);
	session.enrollment.reset(noteId); // next open re-runs the STEP1 handshake
	// A reopen is a user-driven retry — give it a fresh attempt budget, or a note
	// that tripped the breaker would stay deaf for the rest of the session.
	rehandshakeAttempts.delete(noteId);
	const a = session.awareness.get(noteId);
	if (a) {
		a.destroy();
		session.awareness.delete(noteId);
	}
	session.manager.closeDoc(noteId);
}

export function enroll(noteId: string): void {
	session?.enrollment.enroll(noteId);
}

/** Enroll only when the doc is actually live on this client (open in an
 *  editor, or an entry already exists). `crdt_doc_ready` fan-in goes through
 *  here: background notes must NOT materialize Y.Docs — non-open notes are
 *  read via REST, and an open re-handshakes on its own. Keeps client memory
 *  independent of vault size. */
export function enrollIfLive(noteId: string): void {
	if (!session) {
		return;
	}
	if (!(session.openNoteIds.has(noteId) || session.manager.hasDoc(noteId))) {
		return;
	}
	session.enrollment.enroll(noteId);
}

/** Recover from a failed/unacknowledged crdt_msg push by re-running the STEP1
 *  handshake after a delay. The Yjs sync protocol makes this loss-proof: the
 *  server answers STEP2 with exactly the diff it is missing, so a dropped
 *  update is re-derived rather than re-sent (no duplication, no queue).
 *  Deduped per note_id — bursts of error replies collapse into one handshake.
 *  `docId` IS the note_id on the wire now (no vault-prefix stripping needed). */
export function scheduleRehandshake(docId: string, delayMs: number): void {
	if (rehandshakeTimers.has(docId)) {
		return;
	}
	const attempts = rehandshakeAttempts.get(docId) ?? 0;
	if (attempts >= REHANDSHAKE_MAX_ATTEMPTS) {
		// Circuit open: stop the automatic retry storm. Three things re-arm it, so
		// an open breaker is an escapable state rather than a stuck one: a
		// successful crdt_msg ack (clearRehandshakeBackoff), a reconnect/refocus
		// resync (resyncOpenDocs), or a user reopen (closeDoc). All three are
		// naturally rate-limited — a user action, or the 3s resync throttle — which
		// is what keeps re-arming from becoming its own storm. Inbound frames
		// deliberately do NOT re-arm; see handleFrame. Note this does not silence
		// the note: inbound frames still apply while the breaker is open. Loud so a
		// stuck note stays diagnosable.
		rlog().warn(
			"crdt",
			`re-handshake giving up note=${docId} after ${attempts} attempts — awaiting ack/reconnect/reopen`,
		);
		return;
	}
	// Exponential backoff on the caller's base delay, capped. The first failure
	// uses the base delay; each consecutive failure doubles it.
	const backoff = Math.min(delayMs * 2 ** attempts, REHANDSHAKE_MAX_DELAY_MS);
	rehandshakeAttempts.set(docId, attempts + 1);
	rlog().info(
		"crdt",
		`re-handshake scheduled note=${docId} delayMs=${backoff} attempt=${attempts + 1}`,
	);
	rehandshakeTimers.set(
		docId,
		setTimeout(() => {
			rehandshakeTimers.delete(docId);
			if (!session?.manager.hasDoc(docId)) {
				return; // closed since — reopen re-handshakes on its own
			}
			session.enrollment.reset(docId);
			session.enrollment.enroll(docId);
		}, backoff),
	);
}

/** Clear a note's re-handshake backoff + circuit-breaker. Called on a
 *  successful crdt_msg ack (the channel is proven healthy for this note) so the
 *  NEXT genuine failure starts from the base delay with a fresh attempt budget.
 *  Normal editing keeps the backoff clear; only a persistently-failing note
 *  accumulates attempts toward the cap. */
export function clearRehandshakeBackoff(docId: string): void {
	rehandshakeAttempts.delete(docId);
}

export async function handleFrame(noteId: string, b64: string): Promise<void> {
	if (!session) {
		return;
	}
	if (!session.manager.hasDoc(noteId)) {
		return; // not active — drop; STEP1 re-syncs on reopen
	}
	// NOTE: deliberately does NOT clear rehandshakeAttempts. An inbound frame
	// looks like proof the room is healthy, but the failure this breaker exists
	// for is push-side: scheduleRehandshake is fed by crdt_msg REJECTIONS, and
	// `rate_limited` is one of them (see channel.ts). Rate-limited pushes while
	// other devices keep editing means frames keep arriving — so clearing here
	// would reset the budget on every frame and re-handshake without bound,
	// restoring the exact storm this breaker bounds, under exactly the
	// rate-limit starvation that has bitten this codebase before.
	// A tripped breaker is NOT a deaf note: this path is independent of it, so
	// live edits keep applying. Only the re-handshake retry stops, and reconnect,
	// tab refocus (both -> resyncOpenDocs) and reopen (closeDoc) all re-arm it.
	await session.channel.handleFrame(noteId, b64);
}

/** On socket reconnect: clear each open doc's handshake guard and re-enroll it
 *  so a fresh STEP1 is sent. Removes the dependency on the server re-firing
 *  crdt_doc_ready. Open docs are those with a live Awareness entry (created by
 *  openDoc, removed by closeDoc). */
export function resyncOpenDocs(): void {
	if (!session) {
		return;
	}
	// Throttle: a reconnect storm fires this many times per second; one full
	// re-enroll per window recovers, the rest just amplifies the storm.
	const now = Date.now();
	if (now - lastResyncAt < RESYNC_MIN_INTERVAL_MS) {
		return;
	}
	lastResyncAt = now;
	// A reconnect (or a tab refocus) is a new connectivity epoch: attempts racked
	// up against the OLD socket say nothing about this one. Clear the whole map so
	// every open doc re-handshakes with a full budget — mirrors the plugin's
	// `clearStrandHealAttempts()` on `onCrdtTopicJoined`. The throttle above is
	// what keeps this from becoming its own storm.
	rehandshakeAttempts.clear();
	const ids = [...session.awareness.keys()];
	if (ids.length > 0) {
		rlog().info("crdt", `reconnect resync: re-enrolling ${ids.length} open doc(s)`);
	}
	for (const id of ids) {
		session.enrollment.reset(id); // clears enrolled set + CrdtChannel.initiated guard
		session.enrollment.enroll(id); // re-sends STEP1 (idempotent; reset re-armed it)
	}
}

/**
 * Wire tab focus + visibility triggers to re-handshake open CRDT docs.
 *
 * A backgrounded/throttled tab can miss live `crdt_msg` pushes -- the browser
 * may idle-drop frames or keep the socket half-connected so the reconnect path
 * (`resyncOpenDocs` on socket `onOpen`) never fires, leaving the editor diverged
 * with no catch-up signal. On the tab becoming visible/focused we re-run STEP1
 * for every open doc; the server answers STEP2 with only the diff, so it is
 * cheap and idempotent (a no-op when already in sync). Returns a cleanup that
 * removes the listeners.
 */
export function installCrdtResyncTriggers(): () => void {
	const onVisible = () => {
		if (document.visibilityState === "visible") {
			resyncOpenDocs();
		}
	};
	// visibilitychange targets document, not window (does not bubble).
	document.addEventListener("visibilitychange", onVisible);
	window.addEventListener("focus", resyncOpenDocs);
	return () => {
		document.removeEventListener("visibilitychange", onVisible);
		window.removeEventListener("focus", resyncOpenDocs);
	};
}

/** Called by the transport layer when the CRDT Phoenix channel joins OK. */
export function notifyCrdtChannelJoined(): void {
	setCrdtSyncStatus("synced");
}

/** Called by the transport layer when the CRDT Phoenix channel join fails. */
export function notifyCrdtChannelError(): void {
	setCrdtSyncStatus("error");
}

/** Test seam: is `noteId` currently tracked as open in the session? */
export function __isNoteOpen(noteId: string): boolean {
	return session?.openNoteIds.has(noteId) ?? false;
}
