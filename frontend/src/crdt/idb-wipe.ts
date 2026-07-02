import { CRDT_IDB_PREFIX } from "./manager";

function deleteDb(name: string): Promise<void> {
	return new Promise((resolve) => {
		const req = indexedDB.deleteDatabase(name);
		// Resolve on all outcomes: onblocked can fire while a connection is
		// still closing during teardown; the caller retries on the next
		// user-change and the DB is inert (no live session) meanwhile.
		req.onsuccess = () => resolve();
		req.onerror = () => resolve();
		req.onblocked = () => resolve();
	});
}

/** Delete every CRDT IndexedDB database (all vaults). Called on logout /
 *  user switch so plaintext note content does not outlive the session on a
 *  shared machine. Best effort: browsers without indexedDB.databases()
 *  (Firefox <126) no-op — the docs there are unreachable by name. */
export async function wipeCrdtIndexedDb(): Promise<void> {
	if (typeof indexedDB === "undefined" || typeof indexedDB.databases !== "function") {
		return;
	}
	const dbs = await indexedDB.databases();
	const names = dbs
		.map((d) => d.name)
		.filter((n): n is string => Boolean(n?.startsWith(CRDT_IDB_PREFIX)));
	await Promise.all(names.map(deleteDb));
}
