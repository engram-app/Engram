/**
 * IndexedDB persistence for the durable CRDT op queue (#1030). The queue holds
 * only op DESCRIPTORS (create → { path }, delete → {}) — no note content — so
 * this stores a tiny per-(user, vault) `CrdtOp[]` blob that survives a page
 * reload. IndexedDB (not localStorage) because it is async, service-worker
 * reachable, and the substrate a future PWA offline-vault will extend.
 *
 * Degrades to a no-op when IndexedDB is unavailable (private mode / SSR): the
 * queue simply loses durability-across-reloads, keeping its in-memory guarantee.
 */

import type { CrdtOp } from "./op-queue";

const DB_NAME = "engram-crdt-queue";
const STORE = "ops";
const DB_VERSION = 1;

/** IndexedDB handle, or null when the API is absent. Opened lazily, once. */
function openDb(): Promise<IDBDatabase | null> {
	if (typeof indexedDB === "undefined") {
		return Promise.resolve(null);
	}
	return new Promise((resolve) => {
		let req: IDBOpenDBRequest;
		try {
			req = indexedDB.open(DB_NAME, DB_VERSION);
		} catch {
			resolve(null);
			return;
		}
		req.onupgradeneeded = () => {
			if (!req.result.objectStoreNames.contains(STORE)) {
				req.result.createObjectStore(STORE);
			}
		};
		req.onsuccess = () => resolve(req.result);
		req.onerror = () => resolve(null); // treat any open failure as "no store"
		req.onblocked = () => resolve(null);
	});
}

function tx<T>(
	db: IDBDatabase,
	mode: IDBTransactionMode,
	run: (store: IDBObjectStore) => IDBRequest<T>,
): Promise<T> {
	return new Promise((resolve, reject) => {
		const store = db.transaction(STORE, mode).objectStore(STORE);
		const req = run(store);
		req.onsuccess = () => resolve(req.result);
		req.onerror = () => reject(req.error);
	});
}

/**
 * Open the DB, run `fn`, and ALWAYS close the connection afterwards — a lingering
 * open handle blocks `deleteDatabase` and later `versionchange` upgrades. Returns
 * `fallback` when the API is absent or anything throws (best-effort persistence).
 */
async function withDb<T>(fallback: T, fn: (db: IDBDatabase) => Promise<T>): Promise<T> {
	const db = await openDb();
	if (!db) {
		return fallback;
	}
	try {
		return await fn(db);
	} catch {
		return fallback;
	} finally {
		db.close();
	}
}

/** A load/save target for the queue's persisted op list. */
export interface Persister {
	load(): Promise<CrdtOp[]>;
	save(ops: CrdtOp[]): Promise<void>;
	clear(): Promise<void>;
}

/**
 * Build a Persister scoped to one (userId, vaultId) — its own key in the shared
 * store, so switching vault / user reads a different queue and never bleeds ops
 * across contexts.
 */
export function createIndexedDbPersister(userId: string, vaultId: string): Persister {
	const key = `${userId}:${vaultId}`;
	return {
		load(): Promise<CrdtOp[]> {
			return withDb<CrdtOp[]>([], async (db) => {
				const raw = await tx<CrdtOp[] | undefined>(db, "readonly", (s) => s.get(key));
				return Array.isArray(raw) ? raw : [];
			});
		},
		save(ops: CrdtOp[]): Promise<void> {
			return withDb<void>(undefined, async (db) => {
				// Empty → delete the key so a drained queue leaves no residue.
				if (ops.length > 0) {
					await tx(db, "readwrite", (s) => s.put(ops, key));
				} else {
					await tx(db, "readwrite", (s) => s.delete(key));
				}
			});
		},
		clear(): Promise<void> {
			return withDb<void>(undefined, async (db) => {
				await tx(db, "readwrite", (s) => s.delete(key));
			});
		},
	};
}

/** Exported so the sign-out wipe can name it. It sits outside CRDT_IDB_PREFIX
 *  ("engram-crdt/") by one character, so the prefix sweep never matched it and
 *  queued ops — which carry note paths — survived sign-out. */
export const QUEUE_DB_NAME = DB_NAME;
