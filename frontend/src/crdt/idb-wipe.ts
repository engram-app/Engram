import { CRDT_IDB_PREFIX } from "./manager";

const BLOCKED_RETRY_ATTEMPTS = 5;
const BLOCKED_RETRY_DELAY_MS = 300;

function deleteDb(name: string, attempt = 1): Promise<void> {
	return new Promise((resolve) => {
		const req = indexedDB.deleteDatabase(name);
		req.onsuccess = () => resolve();
		req.onerror = () => resolve();
		req.onblocked = () => {
			// onblocked fires when another connection (e.g. manager.destroy hasn't
			// closed the IDB handle yet) is still open.  stopCrdtSession closes
			// connections within milliseconds in the common case, so a short retry
			// window closes the race.  This bounded blocked-retry is the ONLY
			// retry: the caller (useWipeCrdtOnUserChange) fires once per identity
			// change and does not retry, so the race must be resolved here.
			if (attempt < BLOCKED_RETRY_ATTEMPTS) {
				setTimeout(() => {
					deleteDb(name, attempt + 1).then(resolve);
				}, BLOCKED_RETRY_DELAY_MS);
			} else {
				console.warn(
					`[engram] wipeCrdtIndexedDb: "${name}" still blocked after ${BLOCKED_RETRY_ATTEMPTS} attempts — giving up`,
				);
				resolve();
			}
		};
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
