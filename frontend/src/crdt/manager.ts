import { IndexeddbPersistence } from "y-indexeddb";
import * as Y from "yjs";
import { frontmatterMaps } from "./frontmatter-doc";

interface Entry {
	doc: Y.Doc;
	persistence: IndexeddbPersistence;
	text: Y.Text;
	ready: Promise<void>;
}

/**
 * Origin stamped on remotely-applied updates. The single update listener skips
 * these (the server already has them); web has no local file, so there is no
 * disk-flush side effect (unlike the plugin's manager).
 */
export const REMOTE_ORIGIN = "remote";

/** Local IndexedDB namespace for CRDT docs. The wire doc_id is the bare
 *  note_id (globally unique, rename-stable); this prefix exists purely so a
 *  logout wipe can enumerate-and-delete without touching other same-origin
 *  DBs (Clerk, etc.). */
export const CRDT_IDB_PREFIX = "engram-crdt/";

export interface CrdtManagerOptions {
	/** Emitted on every local Y.Doc update (origin !== REMOTE_ORIGIN). */
	onUpdate: (docId: string, update: Uint8Array, origin: unknown) => void;
	/** IndexedDB persistence failure (e.g. quota). Sync continues over the WS. */
	onPersistError?: (noteId: string, err: unknown) => void;
}

export class CrdtManager {
	private readonly opts: CrdtManagerOptions;
	private readonly docs = new Map<string, Entry>();

	private static readonly MAX_CONTENT_BYTES = 500_000;
	private static readonly MAX_CLIENT_IDS = 1000;

	constructor(opts: CrdtManagerOptions) {
		this.opts = opts;
	}

	/** The doc id — identity over the note's stable note_id. Used as both the
	 *  wire doc_id and (with CRDT_IDB_PREFIX) the local IndexedDB key. Rename-
	 *  stable: a path/move never changes this since note_id doesn't change. */
	docId(noteId: string): string {
		return noteId;
	}

	async getDoc(noteId: string): Promise<Y.Doc> {
		return (await this.entry(noteId)).doc;
	}

	/** The shared Y.Text bound to CodeMirror via yCollab. */
	async getSharedText(noteId: string): Promise<Y.Text> {
		return (await this.entry(noteId)).text;
	}

	/** Apply a binary Yjs update from the server (suppresses re-send). */
	async applyRemoteUpdate(noteId: string, update: Uint8Array): Promise<void> {
		const e = await this.entry(noteId);
		Y.applyUpdate(e.doc, update, REMOTE_ORIGIN);
	}

	async encodeStateVector(noteId: string): Promise<Uint8Array> {
		return Y.encodeStateVector((await this.entry(noteId)).doc);
	}

	async encodeStateAsUpdate(noteId: string, sv?: Uint8Array): Promise<Uint8Array> {
		return Y.encodeStateAsUpdate((await this.entry(noteId)).doc, sv);
	}

	/** True if a Y.Doc entry is currently live for this note (opened via openDoc
	 *  or active via enrollment). False after closeDoc. Used to drop late inbound
	 *  frames instead of resurrecting a closed doc. */
	hasDoc(noteId: string): boolean {
		return this.docs.has(this.docId(noteId));
	}

	closeDoc(noteId: string): void {
		const id = this.docId(noteId);
		const e = this.docs.get(id);
		if (!e) {
			return;
		}
		e.doc.destroy();
		e.persistence.destroy();
		this.docs.delete(id);
	}

	async destroy(): Promise<void> {
		for (const [id, e] of this.docs) {
			e.doc.destroy();
			await e.persistence.destroy();
			this.docs.delete(id);
		}
	}

	/**
	 * Flatten to a single-client-ID snapshot only when BOTH thresholds are
	 * crossed (>500 KB AND >1000 client-IDs). Seeds the flattened plaintext with
	 * LOCAL origin so the server adopts the reset lineage. Returns true if flattened.
	 */
	async flattenIfBloated(noteId: string): Promise<boolean> {
		if (!this.docs.has(this.docId(noteId))) {
			return false; // doc not live (closed or never opened) — never resurrect
		}
		const e = await this.entry(noteId);
		const encoded = Y.encodeStateAsUpdate(e.doc);
		const clientIds = Y.decodeStateVector(Y.encodeStateVector(e.doc)).size;
		if (encoded.length < CrdtManager.MAX_CONTENT_BYTES || clientIds < CrdtManager.MAX_CLIENT_IDS) {
			return false;
		}
		const plaintext = e.text.toJSON();
		// #814: capture the frontmatter Y.Maps before destroying the bloated doc,
		// or the flatten silently drops every widget-managed property (the fresh
		// doc only ever gets the plaintext body re-inserted).
		const before = frontmatterMaps(e.doc);
		const fmValues = new Map<string, string>();
		before.values.forEach((v, k) => {
			fmValues.set(k, v);
		});
		const fmOrder = before.order.toArray();
		const fmTypes = new Map<string, string>();
		before.types.forEach((v, k) => {
			fmTypes.set(k, v);
		});

		const id = this.docId(noteId);
		e.doc.destroy();
		await e.persistence.clearData();
		await e.persistence.destroy();
		this.docs.delete(id);
		const fresh = await this.entry(noteId);
		fresh.doc.transact(() => {
			fresh.text.insert(0, plaintext); // local origin → propagated to the server
			const after = frontmatterMaps(fresh.doc);
			for (const [k, v] of fmValues) {
				after.values.set(k, v);
			}
			if (fmOrder.length > 0) {
				after.order.insert(0, fmOrder);
			}
			for (const [k, v] of fmTypes) {
				after.types.set(k, v);
			}
		});
		return true;
	}

	private async entry(noteId: string): Promise<Entry> {
		const id = this.docId(noteId);
		const cached = this.docs.get(id);
		if (cached) {
			await cached.ready;
			return cached;
		}
		const doc = new Y.Doc();
		const persistence = new IndexeddbPersistence(CRDT_IDB_PREFIX + id, doc);
		const text = doc.getText("content");
		persistence.on("error", (err: unknown) => this.opts.onPersistError?.(noteId, err));
		// Single listener: local updates go to the channel; remote-origin updates
		// are skipped. No disk-flush listener — the web has no local file.
		doc.on("update", (update: Uint8Array, origin: unknown) => {
			if (origin === REMOTE_ORIGIN) {
				return;
			}
			this.opts.onUpdate(id, update, origin);
		});
		// y-indexeddb (9.0.12) never fires `synced` once destroy() runs, so a
		// bare whenSynced would hang every awaiter if the doc is closed mid-load.
		// Race it against the doc's "destroy" event (closeDoc/destroy call
		// doc.destroy() before persistence.destroy()) so awaiters ALWAYS resume.
		const destroyed = new Promise<void>((resolve) => doc.on("destroy", () => resolve()));
		const ready: Promise<void> = Promise.race([
			persistence.whenSynced.then(() => undefined),
			destroyed,
		]);
		const entry: Entry = { doc, persistence, text, ready };
		this.docs.set(id, entry);
		await ready;
		return entry;
	}
}
