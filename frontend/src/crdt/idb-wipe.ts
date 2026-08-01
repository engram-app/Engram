import { forgetCrdtDbs, knownCrdtDbs } from "./idb-registry";
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

/** Delete every CRDT IndexedDB database (all vaults). Called on logout / user
 *  switch so plaintext note content does not outlive the session on a shared
 *  machine.
 *
 *  Sources are UNIONED rather than either/or (#873):
 *
 *  - `indexedDB.databases()` enumerates what actually exists, including docs
 *    created before the registry existed and any created by another tab.
 *    Unavailable on Firefox <126, where this used to be the only source and
 *    the whole wipe silently no-opped.
 *  - The registry (`idb-registry`) lists what we created. Always available,
 *    but can miss a doc written by an older build.
 *
 *  Neither is complete alone; together they cover both gaps. Deleting a
 *  database that does not exist is a no-op, so over-listing is free. */
export async function wipeCrdtIndexedDb(): Promise<void> {
	if (typeof indexedDB === "undefined") {
		return;
	}

	const names = new Set<string>(knownCrdtDbs());

	if (typeof indexedDB.databases === "function") {
		const dbs = await indexedDB.databases();
		for (const d of dbs) {
			if (d.name?.startsWith(CRDT_IDB_PREFIX)) {
				names.add(d.name);
			}
		}
	}

	await Promise.all([...names].map((n) => deleteDb(n)));

	// Only after the deletes have settled — a registry cleared up front would
	// lose the names if the page went away mid-wipe, and those databases would
	// then be unreachable on a browser with no enumeration.
	forgetCrdtDbs();
}
