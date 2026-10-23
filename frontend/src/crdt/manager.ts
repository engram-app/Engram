import { IndexeddbPersistence } from "y-indexeddb";
import * as Y from "yjs";
import { rememberCrdtDb } from "./idb-registry";
import { crdtMark } from "./perf";

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

	/** The shared Y.Text bound to CodeMirror via yCollab.
	 *
	 *  The ONLY `entry()` caller on the note-open path, and therefore the only
	 *  one that times it — see `entry`'s `timed` parameter. */
	async getSharedText(noteId: string): Promise<Y.Text> {
		return (await this.entry(noteId, true)).text;
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

	/** `timed` gates the open-path perf marks. Every other caller — `getDoc`
	 *  from the channel bridge, `applyRemoteUpdate` from the frame handler,
	 *  the state-vector helpers — runs on inbound TRAFFIC, not on an open, and
	 *  stamping there attributed a collaborator's edit to whatever open was
	 *  last seen for that note. Marks belong where they mean what they say. */
	private async entry(noteId: string, timed = false): Promise<Entry> {
		const id = this.docId(noteId);
		const cached = this.docs.get(id);
		if (cached) {
			if (timed) {
				crdtMark(noteId, "entry:warm");
			}
			await cached.ready;
			return cached;
		}
		if (timed) {
			crdtMark(noteId, "entry:cold");
		}
		const doc = new Y.Doc();
		const dbName = CRDT_IDB_PREFIX + id;
		// Write the name down BEFORE opening it: on a browser with no
		// indexedDB.databases() the logout wipe has no other way to find this
		// database, and a crash between open and register would strand plaintext
		// note content on disk (#873).
		rememberCrdtDb(dbName);
		const persistence = new IndexeddbPersistence(dbName, doc);
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
		if (timed) {
			crdtMark(noteId, "idb:synced");
		}
		return entry;
	}
}
