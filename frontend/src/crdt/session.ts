import { Awareness } from "y-protocols/awareness";
import type * as Y from "yjs";
import { CrdtChannel } from "./channel";
import { CrdtEnrollment } from "./enrollment";
import { CrdtManager } from "./manager";

interface Session {
	vaultId: string;
	manager: CrdtManager;
	channel: CrdtChannel;
	enrollment: CrdtEnrollment;
	awareness: Map<string, Awareness>;
	/** Paths currently open in the editor (via openDoc / closeDoc). Used to
	 *  guard flattenIfBloated so a live editor doc is never destroyed. */
	openPaths: Set<string>;
}

let session: Session | null = null;

// ── Sync status ────────────────────────────────────────────────────────────
export type CrdtSyncStatus = "connecting" | "synced" | "error";

let syncStatus: CrdtSyncStatus = "connecting";
const syncStatusListeners = new Set<(s: CrdtSyncStatus) => void>();

export function getCrdtSyncStatus(): CrdtSyncStatus {
	return syncStatus;
}

export function subscribeToCrdtSyncStatus(cb: (s: CrdtSyncStatus) => void): () => void {
	syncStatusListeners.add(cb);
	return () => syncStatusListeners.delete(cb);
}

function setCrdtSyncStatus(s: CrdtSyncStatus): void {
	if (syncStatus === s) {
		return;
	}
	syncStatus = s;
	for (const cb of syncStatusListeners) {
		cb(s);
	}
}

export interface StartSessionOpts {
	vaultId: string;
	/** Transport out: push a base64 y-protocols frame for docId to the server. */
	push: (docId: string, b64: string) => void;
	onPersistError?: (path: string, err: unknown) => void;
}

export function startCrdtSession(opts: StartSessionOpts): void {
	stopCrdtSession();
	setCrdtSyncStatus("connecting");
	// Declare channel first so the onUpdate closure can reference it.
	// channel is assigned before any update tick fires.
	let channel: CrdtChannel;
	const manager = new CrdtManager({
		dbPrefix: opts.vaultId,
		onUpdate: (docId, update) => channel.sendUpdateRaw(docId, update),
		onPersistError: opts.onPersistError,
	});
	channel = new CrdtChannel({ manager, send: opts.push });
	const openPaths = new Set<string>();
	const enrollment = new CrdtEnrollment({
		startSync: (p) => channel.startSync(p),
		resetSync: (p) => channel.resetSync(p),
		onAfterEnroll: (p) => {
			// Skip flatten while the doc is open in an editor -- destroying and
			// rebuilding the Y.Doc would leave the editor bound to a dead doc.
			if (openPaths.has(p)) {
				return Promise.resolve();
			}
			return manager.flattenIfBloated(p).then(() => undefined);
		},
	});
	session = {
		vaultId: opts.vaultId,
		manager,
		channel,
		enrollment,
		awareness: new Map(),
		openPaths,
	};
}

export function stopCrdtSession(): void {
	if (!session) {
		return;
	}
	for (const a of session.awareness.values()) {
		a.destroy();
	}
	void session.manager.destroy().catch((e) => console.warn("CRDT session teardown error", e));
	session = null;
}

export async function openDoc(
	path: string,
): Promise<{ ytext: Y.Text; awareness: Awareness; doc: Y.Doc } | null> {
	if (!(session && path.endsWith(".md"))) {
		return null;
	}
	session.openPaths.add(path);
	const ytext = await session.manager.getSharedText(path);
	let awareness = session.awareness.get(path);
	if (!awareness) {
		awareness = new Awareness(ytext.doc!);
		session.awareness.set(path, awareness);
	}
	return { ytext, awareness, doc: ytext.doc! };
}

export function closeDoc(path: string): void {
	if (!session) {
		return;
	}
	session.openPaths.delete(path);
	const a = session.awareness.get(path);
	if (a) {
		a.destroy();
		session.awareness.delete(path);
	}
	session.manager.closeDoc(path);
}

export function enroll(path: string): void {
	session?.enrollment.enroll(path);
}

export async function handleFrame(path: string, b64: string): Promise<void> {
	if (!session) {
		return;
	}
	if (!session.manager.hasDoc(path)) {
		return; // not active — drop; STEP1 re-syncs on reopen
	}
	await session.channel.handleFrame(path, b64);
}

/** On socket reconnect: clear each open doc's handshake guard and re-enroll it
 *  so a fresh STEP1 is sent. Removes the dependency on the server re-firing
 *  crdt_doc_ready. Open docs are those with a live Awareness entry (created by
 *  openDoc, removed by closeDoc). */
export function resyncOpenDocs(): void {
	if (!session) {
		return;
	}
	for (const path of session.awareness.keys()) {
		session.enrollment.reset(path); // clears enrolled set + CrdtChannel.initiated guard
		session.enrollment.enroll(path); // re-sends STEP1 (idempotent; reset re-armed it)
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

export function docPathFromDocId(docId: string): string {
	const idx = docId.indexOf("/");
	return idx === -1 ? docId : docId.slice(idx + 1);
}
