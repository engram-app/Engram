import type { QueryClient } from "@tanstack/react-query";
import { type Channel, Socket } from "phoenix";
import {
	enrollIfLive as crdtEnrollIfLive,
	handleFrame as crdtHandleFrame,
	notifyCrdtChannelError,
	notifyCrdtChannelJoined,
	resyncOpenDocs,
	scheduleRehandshake as scheduleCrdtRehandshake,
	startCrdtSession,
	stopCrdtSession,
} from "../crdt/session";
import { beacon, parseTraceparent, tracingEnabled } from "../observability/trace";
import { getWsBase, joinWsUrl } from "./base";
import { ROOT_FOLDER_ID } from "./queries";

// phoenix.js's own default reconnect steps — kept for the 2nd+ attempt. Only
// the FIRST reconnect is full-jittered, to de-sync a drained fleet so the
// freshly-booted node isn't stampeded.
const PHX_RECONNECT_STEPS = [10, 50, 100, 150, 200, 250, 500, 1000, 2000];

// Wake-from-idle window: a single laptop-wake/tab-foreground emits focus,
// visibilitychange, and (if the network re-established) online in quick
// succession. Coalesce that burst (trailing edge) into one action so the
// strongest signal in the window wins (installSocketHealthTriggers).
const WAKE_COALESCE_MS = 500;

// A tab hidden longer than this is treated as possibly half-open on return, so
// wake forces a (cheap, session-preserving) reconnect rather than trusting
// isConnected(). ponytail: sits below phoenix's 30s heartbeat interval so we
// recover before the heartbeat would; raise it if quick tab-flips churn too much.
const STALE_HIDDEN_MS = 15_000;

let serverJitterMs: number | null = null;

let socket: Socket | null = null;
let channel: Channel | null = null;
let crdtChannel: Channel | null = null;

// Bumped by disconnectChannel (which connectChannel calls at entry, and which
// also runs on effect teardown / vault switch). connectChannel captures it
// after that bump and bails if it changed across `await getToken()` — so a
// connect superseded by a later connect or a teardown mid-token-fetch never
// binds the singletons to a stale socket/vault. Mirrors crdt/session's
// sessionGeneration guard.
let connectGeneration = 0;

// The socket's params are a FUNCTION, so phoenix re-reads the token on every
// (re)connect (a static object would freeze the token phoenix replays forever —
// after a long idle that token is expired and every reconnect fails auth, which
// is why the socket never self-heals until a page reload). reconnectWithFreshToken
// updates this before reconnecting; phoenix's own heartbeat/visibility reconnects
// then pick up whatever's current.
let latestToken: string | null = null;

interface ConnectOptions {
	userId: string;
	vaultId: string;
	getToken: () => Promise<string | null>;
	queryClient: QueryClient;
	onSocketOpen?: () => void;
}

type NoteChangedListener = (payload: NoteChangedPayload) => void;
const listeners = new Set<NoteChangedListener>();

// ── Coalesced list invalidation ───────────────────────────────────────────
// A plugin sync burst delivers one note_changed per note (hundreds in a
// row). Invalidating every folder/search list per event refetched
// O(events × active queries) against a backend that decrypts rows
// server-side — the per-note keys stay synchronous (cheap, exact), but
// list-level keys batch into one targeted flush per window.

const BATCH_WINDOW_MS = 250;

interface PendingBatch {
	queryClient: QueryClient;
	vaultId: string;
	folders: Set<string>;
	timer: ReturnType<typeof setTimeout>;
}

let pending: PendingBatch | null = null;

function folderFromPath(path: string): string {
	const idx = path.lastIndexOf("/");
	return idx === -1 ? "" : path.slice(0, idx);
}

interface CachedFolders {
	folders?: Array<{ id: string; name: string }>;
}

function flushBatch(batch: PendingBatch): void {
	const { queryClient, vaultId, folders } = batch;
	queryClient.invalidateQueries({ queryKey: ["folders", vaultId] });
	queryClient.invalidateQueries({ queryKey: ["search", vaultId] });

	// The by-id keys are keyed on folder-marker ids; resolve names through
	// the cached tree. Unknown folders (just created, tree not refetched
	// yet) fall back to one broad invalidation.
	const cached = queryClient.getQueryData<CachedFolders>(["folders", vaultId]);
	let broadById = false;

	// refetchType "all" (not the default "active"): the tree loader
	// (viewer/tree/loader.ts) reads these caches with a raw getQueryData check
	// and only fetches on a genuine cache miss, so a folder whose notes were
	// loaded once (via fetchQuery/prefetchQuery) but has no live useQuery
	// observer, meaning any subfolder besides the root (the only one with a
	// mounted `useFolderNotesById`), would otherwise sit invalidated but
	// unfetched forever, never converging a cross-tab move/delete into that
	// folder.
	for (const folder of folders) {
		queryClient.invalidateQueries({
			queryKey: ["folderNotes", vaultId, folder],
			refetchType: "all",
		});
		// Root has no folder marker; its id-keyed list keys under the sentinel.
		if (folder === "") {
			queryClient.invalidateQueries({
				queryKey: ["folder-notes-by-id", vaultId, ROOT_FOLDER_ID],
				refetchType: "all",
			});
			continue;
		}
		const entry = cached?.folders?.find((f) => f.name === folder);
		if (entry) {
			queryClient.invalidateQueries({
				queryKey: ["folder-notes-by-id", vaultId, entry.id],
				refetchType: "all",
			});
		} else {
			broadById = true;
		}
	}

	if (broadById) {
		queryClient.invalidateQueries({
			queryKey: ["folder-notes-by-id", vaultId],
			refetchType: "all",
		});
	}
}

export const RECONNECT_JITTER_DEFAULT_MS = 5000;
export const RECONNECT_JITTER_MAX_MS = 60_000;

export function clampReconnectJitter(raw: unknown): number | null {
	if (typeof raw !== "number" || !Number.isFinite(raw) || raw <= 0) {
		return null;
	}
	return Math.min(raw, RECONNECT_JITTER_MAX_MS);
}

export function computeReconnectMs(
	tries: number,
	jitterMaxMs: number | null,
	rng: () => number = Math.random,
): number {
	if (tries <= 1) {
		return rng() * (jitterMaxMs ?? RECONNECT_JITTER_DEFAULT_MS);
	}
	return PHX_RECONNECT_STEPS[tries - 1] ?? 5000;
}

/** Cache the server-advertised jitter window from the sync join reply.
 *  Clamped + validated so a malformed/hostile payload can't make the client
 *  hang or hammer. Non-positive windows (including 0) are rejected, forcing
 *  the client to fall back to the default floor rather than disabling jitter. */
export function captureServerJitter(resp: unknown): void {
	const raw = (resp as { reconnect_jitter_max_ms?: unknown })?.reconnect_jitter_max_ms;
	const clamped = clampReconnectJitter(raw);
	if (clamped !== null) {
		serverJitterMs = clamped;
	}
}

/** Test seams. */
export function __getServerJitterMs(): number | null {
	return serverJitterMs;
}
export function __resetServerJitterMs(): void {
	serverJitterMs = null;
}

export interface NoteChangedPayload {
	event_type: string;
	path: string;
	vault_id: string;
	// Present since backend change_json adds note id. Always invalidate by id
	// when available — useNote keys by id since the URL-by-id refactor.
	id?: string;
	content?: string;
	title?: string;
	folder?: string;
	tags?: string[];
	mtime?: number;
	updated_at?: string;
	version?: number;
	// Distributed trace leg B: the `sync.fanout` span's W3C traceparent,
	// stamped into the payload by the backend. The browser parents its
	// `browser.live_sync.render` beacon onto it. Absent when OTEL is off.
	traceparent?: string;
}

/** Test hook: drop any pending batch without flushing. */
export function __resetNoteChangeBatch(): void {
	if (pending) {
		clearTimeout(pending.timer);
		pending = null;
	}
}

export function handleNoteChanged(
	payload: NoteChangedPayload,
	queryClient: QueryClient,
	activeVaultId: string,
): void {
	// Server broadcasts on the vault topic; this guard protects against
	// an unrelated vault's payload reaching the wrong queryClient (e.g.
	// mid-vault-switch race).
	if (payload.vault_id !== activeVaultId) {
		return;
	}

	// Leg-B trace timing. Gate BEFORE any tracing work: disabled = one
	// boolean, no id parse, no enqueue. Capture the start now so the beacon
	// spans the actual apply below.
	const traced = tracingEnabled() && Boolean(payload.traceparent);
	const startUs = traced ? Date.now() * 1000 : 0;

	if (payload.id !== undefined) {
		queryClient.invalidateQueries({ queryKey: ["note", activeVaultId, payload.id] });
	}
	// Legacy path-keyed key still in use by some hooks; keep invalidating it.
	queryClient.invalidateQueries({ queryKey: ["note", activeVaultId, payload.path] });

	if (!pending) {
		const batch: PendingBatch = {
			queryClient,
			vaultId: activeVaultId,
			folders: new Set(),
			timer: setTimeout(() => {
				pending = null;
				flushBatch(batch);
			}, BATCH_WINDOW_MS),
		};
		pending = batch;
	}

	pending.folders.add(payload.folder ?? folderFromPath(payload.path));

	for (const listener of listeners) {
		listener(payload);
	}

	// Live-sync render leg: report a beacon parented onto the fan-out span so
	// the Tempo trace closes obsidian.push -> backend -> browser render.
	// enqueue is O(1) and never networks on the render path; the shared
	// buffer batches/flushes on its own timer. Best-effort: a bad traceparent
	// just skips.
	if (traced) {
		const parsed = parseTraceparent(payload.traceparent as string);
		if (parsed) {
			beacon.enqueue({
				trace_id: parsed.traceId,
				parent_span_id: parsed.parentSpanId,
				name: "browser.live_sync.render",
				start_us: startUs,
				end_us: Date.now() * 1000,
				attributes: {
					"engram.surface": "web",
					"engram.event_type": payload.event_type ?? "note_changed",
				},
			});
		}
	}
}

// Bulk pushes (POST /api/notes/batch) broadcast ONE notes.batch digest
// (op "upsert", metadata-only entries) instead of N note_changed events.
// Re-feed each entry through handleNoteChanged so per-note keys invalidate
// synchronously and list keys ride the same coalescing window.
export interface NotesBatchPayload {
	op: string;
	vault_id?: string;
	notes?: Array<{
		id: string;
		path: string;
		folder?: string;
		title?: string;
		tags?: string[];
		mtime?: number;
		version?: number;
		updated_at?: string;
		content_hash?: string;
	}>;
}

export function handleNotesBatch(
	payload: NotesBatchPayload,
	queryClient: QueryClient,
	activeVaultId: string,
): void {
	if (payload.op !== "upsert") {
		return;
	}
	if (payload.vault_id !== activeVaultId) {
		return;
	}

	for (const note of payload.notes ?? []) {
		handleNoteChanged(
			{ event_type: "upsert", vault_id: activeVaultId, ...note },
			queryClient,
			activeVaultId,
		);
	}
}

/** A folder marker was created/deleted/moved on the server (from the web app or
 *  the plugin). The tree renders from the ["folders", vaultId] query, so a
 *  single invalidation refetches it — the created folder appears, the deleted
 *  one drops — instead of waiting for a full reload. The event is already
 *  vault-scoped by the sync topic, so the payload carries no vault_id to check. */
export function handleFoldersBatch(
	_payload: { op?: string; folder?: string },
	queryClient: QueryClient,
	vaultId: string,
): void {
	queryClient.invalidateQueries({ queryKey: ["folders", vaultId] });
}

export async function connectChannel({
	userId,
	vaultId,
	getToken,
	queryClient,
	onSocketOpen,
}: ConnectOptions) {
	disconnectChannel();
	const gen = connectGeneration;

	const token = await getToken();

	// Superseded during the token fetch (a later connectChannel or a teardown
	// ran disconnectChannel, bumping the generation). Abort before touching the
	// singletons so we don't bind them to this now-stale connect.
	if (gen !== connectGeneration) {
		return;
	}

	latestToken = token ?? "";
	socket = new Socket(joinWsUrl(getWsBase(), "/socket"), {
		params: () => ({ token: latestToken ?? "" }),
		reconnectAfterMs: (tries: number) => computeReconnectMs(tries, serverJitterMs),
	});

	socket.connect();

	// Fires on initial connect AND every reconnect — the durable-feed catch-up
	// trigger. The socket can drop events while disconnected (no replay), so a
	// reconnect kicks a cursor pull to backfill the gap.
	// Also re-arms CRDT handshakes on reconnect so the session re-syncs state.
	socket.onOpen(() => {
		resyncOpenDocs();
		onSocketOpen?.();
	});

	const topic = `sync:${userId}:${vaultId}`;
	channel = socket.channel(topic);

	channel.on("note_changed", (payload: NoteChangedPayload) => {
		handleNoteChanged(payload, queryClient, vaultId);
	});

	channel.on("notes.batch", (payload: NotesBatchPayload) => {
		handleNotesBatch(payload, queryClient, vaultId);
	});

	channel.on("folders.batch", (payload: { op?: string; folder?: string }) => {
		handleFoldersBatch(payload, queryClient, vaultId);
	});

	channel
		.join()
		.receive("ok", (resp) => {
			captureServerJitter(resp);
		})
		.receive("error", (resp) => console.error("Channel join failed", resp));

	// CRDT note-sync channel — rides the same Clerk-authed socket. The session
	// singleton owns the Y.Doc registry; this channel is just its transport.
	startCrdtSession({
		vaultId,
		push: (docId, b64) => {
			crdtChannel
				?.push("crdt_msg", { doc_id: docId, b64 })
				.receive("error", (resp: { reason?: string }) => {
					if (resp?.reason === "frame_too_large") {
						// Retrying would re-send the same oversized diff and loop.
						console.error(`CRDT frame rejected (frame_too_large) for ${docId} — edit not synced`);
						return;
					}
					// rate_limited or unknown error: a STEP1 re-handshake after a
					// backoff re-derives whatever the server missed.
					scheduleCrdtRehandshake(docId, resp?.reason === "rate_limited" ? 2000 : 1000);
				})
				.receive("timeout", () => scheduleCrdtRehandshake(docId, 1000));
		},
	});
	const crdtTopic = `crdt:${userId}:${vaultId}`;
	crdtChannel = socket.channel(crdtTopic, { crdt_proto: 2 });
	// doc_id IS the note_id on the wire (id-keyed CRDT doc_id) — no path
	// splitting needed.
	crdtChannel.on("crdt_msg", (p: { doc_id: string; b64: string }) => {
		crdtHandleFrame(p.doc_id, p.b64).catch((err) =>
			console.warn("CRDT frame handling error (dropped)", err),
		);
	});
	crdtChannel.on("crdt_doc_ready", (p: { doc_id: string }) => {
		crdtEnrollIfLive(p.doc_id);
	});
	crdtChannel
		.join()
		.receive("ok", () => {
			notifyCrdtChannelJoined();
		})
		.receive("error", (resp) => {
			notifyCrdtChannelError();
			console.error("CRDT channel join failed", resp);
		});
}

/** True when the live-sync socket exists and Phoenix reports it OPEN. Note: a
 *  truly half-open socket (TCP dead, Phoenix hasn't seen the close) still reads
 *  OPEN here — the wake trigger's online/long-hidden signals cover that case,
 *  since isConnected() alone can't distinguish half-open from live. */
export function isSocketConnected(): boolean {
	return socket?.isConnected() ?? false;
}

/**
 * Reconnect the live socket with a freshly-minted token, WITHOUT tearing down
 * the CRDT session. `socket.disconnect()` + `socket.connect()` re-establishes
 * the transport in place: phoenix re-reads the (now-refreshed) params token and
 * re-joins both channels (they enter `errored` on close and rejoin on reopen),
 * and the existing `socket.onOpen` re-runs `resyncOpenDocs` (STEP1 delivers any
 * edits made while disconnected) + the cursor backfill. Because the Y.Docs and
 * the CRDT session are never destroyed, an open editor stays bound to its live
 * doc — no rebind, no lost keystrokes.
 *
 * No-op when there is no live socket (the mount effect owns the initial connect).
 */
export async function reconnectWithFreshToken(
	getToken: () => Promise<string | null>,
): Promise<void> {
	if (!socket) {
		return;
	}
	const gen = connectGeneration;
	const token = await getToken();
	// A vault switch / teardown (disconnectChannel bumps the generation and nulls
	// the socket) ran during the token fetch — don't reconnect a dead/replaced socket.
	if (gen !== connectGeneration || !socket) {
		return;
	}
	latestToken = token ?? "";
	// Reconnect only AFTER teardown completes: phoenix's disconnect() tears the
	// conn down asynchronously (sets `disconnecting`), and a synchronous connect()
	// would start a second conn mid-teardown. The callback runs once the old conn
	// is fully closed; connect() then re-reads params (fresh token) and the errored
	// channels rejoin. Re-check the generation + identity inside the callback: a
	// vault switch / teardown can land during phoenix's (~1.5s) async close, and
	// reviving `s` then would leak an orphaned socket with a stale-vault onOpen.
	const s = socket;
	s.disconnect(() => {
		if (gen === connectGeneration && socket === s) {
			s.connect();
		}
	});
}

/**
 * Install the socket-health triggers: on tab focus / visibilitychange→visible /
 * online, either reconnect (fresh-token, session-preserving) or just backfill.
 *
 * The existing focus-only cursor-sync and CRDT-resync triggers assume the socket
 * is alive; after a long idle or laptop sleep it can be half-open with no
 * `onclose`, so nothing re-establishes it and live updates stop until a reload.
 * `reconnect` fires when the socket is dead, or when the wake signal implies it's
 * stale despite reading OPEN: an `online` transition (network changed) or a long
 * hidden gap. A live socket on a short wake just runs `backfill`. Both are
 * injected; `isConnected` is injectable for tests. Returns a listener cleanup.
 */
export function installSocketHealthTriggers(
	reconnect: () => void,
	backfill: () => void,
	isConnected: () => boolean = isSocketConnected,
): () => void {
	let timer: ReturnType<typeof setTimeout> | null = null;
	let pendingForce = false;
	let hiddenAt: number | null = null;
	// Trailing-edge coalesce: OR every event's force flag across the burst, then
	// act ONCE when it settles. Leading-edge would let an early `focus` (which
	// reads a half-open socket as "connected" → backfill) swallow the later
	// `online`/stale-visible event whose whole job is to force the reconnect
	// through that lie — the exact case this fix targets.
	const schedule = (forceReconnect: boolean) => {
		pendingForce ||= forceReconnect;
		if (timer !== null) {
			return;
		}
		timer = setTimeout(() => {
			timer = null;
			const force = pendingForce;
			pendingForce = false;
			if (force || !isConnected()) {
				reconnect();
			} else {
				backfill();
			}
		}, WAKE_COALESCE_MS);
	};
	const onVisible = () => {
		if (document.visibilityState === "hidden") {
			hiddenAt = Date.now();
			return;
		}
		// Back to visible: a socket hidden longer than the staleness window may be
		// half-open (isConnected() can't tell), so force a reconnect.
		const stale = hiddenAt !== null && Date.now() - hiddenAt > STALE_HIDDEN_MS;
		hiddenAt = null;
		schedule(stale);
	};
	// A network transition almost always means the old socket is stale — and it's
	// the one signal where isConnected() most reliably lies (half-open). Force it.
	const onOnline = () => schedule(true);
	const onFocus = () => schedule(false);
	// visibilitychange targets document, not window (does not bubble).
	document.addEventListener("visibilitychange", onVisible);
	window.addEventListener("online", onOnline);
	window.addEventListener("focus", onFocus);
	return () => {
		if (timer !== null) {
			clearTimeout(timer);
		}
		document.removeEventListener("visibilitychange", onVisible);
		window.removeEventListener("online", onOnline);
		window.removeEventListener("focus", onFocus);
	};
}

export function disconnectChannel() {
	connectGeneration++;
	__resetNoteChangeBatch();
	if (crdtChannel) {
		crdtChannel.leave();
		crdtChannel = null;
	}
	stopCrdtSession();
	if (channel) {
		channel.leave();
		channel = null;
	}
	if (socket) {
		socket.disconnect();
		socket = null;
	}
}
