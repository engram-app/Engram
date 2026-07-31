import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { forgetCrdtDbs, knownCrdtDbs, rememberCrdtDb } from "./idb-registry";
import { wipeCrdtIndexedDb } from "./idb-wipe";
import { CRDT_IDB_PREFIX } from "./manager";

/** Collects deleteDatabase calls; every request succeeds on the first attempt. */
function stubIndexedDb(opts: { enumerate?: string[] | null }): string[] {
	const deleted: string[] = [];
	const base: Record<string, unknown> = {
		deleteDatabase: (name: string) => {
			deleted.push(name);
			const req: Record<string, unknown> = {};
			queueMicrotask(() => (req.onsuccess as () => void)?.());
			return req;
		},
	};
	// `enumerate: null` models Firefox <126 / older Safari: indexedDB exists,
	// indexedDB.databases does not.
	if (opts.enumerate !== null) {
		base.databases = async () => (opts.enumerate ?? []).map((name) => ({ name }));
	}
	vi.stubGlobal("indexedDB", base);
	return deleted;
}

describe("wipeCrdtIndexedDb", () => {
	beforeEach(() => {
		forgetCrdtDbs();
	});

	afterEach(() => {
		vi.unstubAllGlobals();
		vi.useRealTimers();
		forgetCrdtDbs();
	});

	it("deletes every DB with the engram-crdt/ prefix and nothing else", async () => {
		const deleted: string[] = [];
		vi.stubGlobal("indexedDB", {
			databases: async () => [
				{ name: `${CRDT_IDB_PREFIX}v1/notes/a.md` },
				{ name: `${CRDT_IDB_PREFIX}v2/notes/b.md` },
				{ name: "clerk-telemetry" },
				{ name: undefined },
			],
			deleteDatabase: (name: string) => {
				deleted.push(name);
				const req: Record<string, unknown> = {};
				queueMicrotask(() => (req.onsuccess as () => void)?.());
				return req;
			},
		});
		await wipeCrdtIndexedDb();
		expect(deleted).toEqual([`${CRDT_IDB_PREFIX}v1/notes/a.md`, `${CRDT_IDB_PREFIX}v2/notes/b.md`]);
	});

	// #873. This used to assert a NO-OP, which was the bug: on Firefox <126 the
	// logout wipe found nothing to iterate and silently left every CRDT database
	// — i.e. plaintext note content — on disk for the next user of the machine.
	// The registry is the only source of names there.
	it("deletes registry-known DBs when indexedDB.databases is unavailable", async () => {
		const a = `${CRDT_IDB_PREFIX}v1/note-a`;
		const b = `${CRDT_IDB_PREFIX}v1/note-b`;
		rememberCrdtDb(a);
		rememberCrdtDb(b);

		const deleted = stubIndexedDb({ enumerate: null });
		await wipeCrdtIndexedDb();

		expect(deleted.sort()).toEqual([a, b].sort());
	});

	// Neither source is complete on its own: enumeration sees docs written by a
	// build that predates the registry (or by another tab), the registry sees
	// what this tab created. Union, don't choose.
	it("unions enumeration with the registry, without double-deleting", async () => {
		const onlyEnumerated = `${CRDT_IDB_PREFIX}legacy/from-old-build`;
		const onlyRemembered = `${CRDT_IDB_PREFIX}v1/only-in-registry`;
		const both = `${CRDT_IDB_PREFIX}v1/in-both`;

		rememberCrdtDb(onlyRemembered);
		rememberCrdtDb(both);

		const deleted = stubIndexedDb({ enumerate: [onlyEnumerated, both, "clerk-telemetry"] });
		await wipeCrdtIndexedDb();

		expect(deleted.sort()).toEqual([onlyEnumerated, onlyRemembered, both].sort());
		// "clerk-telemetry" is same-origin but not ours.
		expect(deleted).not.toContain("clerk-telemetry");
		// Exactly once each, despite `both` appearing in two sources.
		expect(new Set(deleted).size).toBe(deleted.length);
	});

	it("clears the registry once the deletes have settled", async () => {
		rememberCrdtDb(`${CRDT_IDB_PREFIX}v1/note-a`);
		stubIndexedDb({ enumerate: [] });

		expect(knownCrdtDbs()).toHaveLength(1);
		await wipeCrdtIndexedDb();
		expect(knownCrdtDbs()).toEqual([]);
	});

	it("still resolves when there is nothing to delete at all", async () => {
		stubIndexedDb({ enumerate: [] });
		await expect(wipeCrdtIndexedDb()).resolves.toBeUndefined();
	});

	it("no-ops when indexedDB itself is absent", async () => {
		rememberCrdtDb(`${CRDT_IDB_PREFIX}v1/note-a`);
		vi.stubGlobal("indexedDB", undefined);
		await expect(wipeCrdtIndexedDb()).resolves.toBeUndefined();
		// Registry survives — the databases are still there to delete later.
		expect(knownCrdtDbs()).toHaveLength(1);
	});

	it("retries after onblocked and resolves when the second attempt succeeds", async () => {
		vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });

		const attempts: string[] = [];
		const DB_NAME = `${CRDT_IDB_PREFIX}vault/note.md`;

		vi.stubGlobal("indexedDB", {
			databases: async () => [{ name: DB_NAME }],
			deleteDatabase: (name: string) => {
				attempts.push(name);
				const req: Record<string, unknown> = {};
				if (attempts.length === 1) {
					// First call: fire onblocked
					queueMicrotask(() => (req.onblocked as () => void)?.());
				} else {
					// Second call: succeed
					queueMicrotask(() => (req.onsuccess as () => void)?.());
				}
				return req;
			},
		});

		const wipePromise = wipeCrdtIndexedDb();
		// Flush microtasks so the first deleteDatabase's queueMicrotask fires onblocked
		await Promise.resolve();
		await Promise.resolve();
		// Advance past the 300 ms retry delay so the setTimeout fires
		await vi.advanceTimersByTimeAsync(300);
		// Flush microtasks so the second deleteDatabase's queueMicrotask fires onsuccess
		await Promise.resolve();
		await Promise.resolve();

		await wipePromise;

		expect(attempts).toHaveLength(2);
		expect(attempts).toEqual([DB_NAME, DB_NAME]);
	});
});
