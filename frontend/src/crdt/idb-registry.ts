/**
 * A record of every CRDT IndexedDB database this origin has created.
 *
 * Exists because `indexedDB.databases()` — the only way to *enumerate* what
 * exists — is unavailable on Firefox <126 (and Safari shipped it late). There,
 * the logout wipe had nothing to iterate and silently no-opped, leaving
 * plaintext note content on disk for the next user of a shared machine (#873).
 *
 * We do not actually need enumeration: we create these databases, so we know
 * their names. This writes each one down as it is created, and the wipe unions
 * that list with whatever enumeration reports.
 *
 * Deliberately its own module rather than living in `idb-wipe.ts`: that file
 * imports `CRDT_IDB_PREFIX` from `manager.ts`, and `manager.ts` is the thing
 * that needs to call `rememberCrdtDb`, so putting it there would close an
 * import cycle.
 *
 * localStorage, not IndexedDB: the registry has to be readable when the thing
 * it describes may be unopenable, and it holds only database names — no note
 * content — so it is not itself a disclosure risk.
 */

const REGISTRY_KEY = "engram-crdt-dbs";

/**
 * localStorage throws rather than returning null in a few real cases: Safari
 * private mode historically threw on write, and any browser throws on access
 * when the origin has storage blocked. It is also simply absent under SSR and
 * in some test environments.
 *
 * Degrading to "no registry" is correct in all of those — the wipe still runs
 * its enumeration path, which is exactly the behaviour before this file
 * existed. What we must never do is let a storage error escape into a logout.
 */
function readRegistry(): string[] {
	try {
		const raw = globalThis.localStorage?.getItem(REGISTRY_KEY);
		if (!raw) {
			return [];
		}
		const parsed: unknown = JSON.parse(raw);
		return Array.isArray(parsed) ? parsed.filter((n): n is string => typeof n === "string") : [];
	} catch {
		return [];
	}
}

function writeRegistry(names: string[]): void {
	try {
		globalThis.localStorage?.setItem(REGISTRY_KEY, JSON.stringify(names));
	} catch {
		// Quota or blocked storage. The wipe degrades to enumeration-only, which
		// is the pre-#873 behaviour — worth no more than losing the fallback.
	}
}

/** Record a CRDT database name so the logout wipe can find it without
 *  `indexedDB.databases()`. Idempotent; safe to call on every doc open. */
export function rememberCrdtDb(name: string): void {
	const names = readRegistry();
	if (names.includes(name)) {
		return;
	}
	names.push(name);
	writeRegistry(names);
}

/** Every CRDT database name this origin is known to have created. */
export function knownCrdtDbs(): string[] {
	return readRegistry();
}

/** Drop the registry. Called by the wipe once the databases are gone, so the
 *  list does not grow without bound across sessions. */
export function forgetCrdtDbs(): void {
	try {
		globalThis.localStorage?.removeItem(REGISTRY_KEY);
	} catch {
		// Same rationale as writeRegistry: a stale registry only costs a few
		// no-op deleteDatabase calls on the next wipe.
	}
}
