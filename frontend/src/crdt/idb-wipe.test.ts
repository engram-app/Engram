import { afterEach, describe, expect, it, vi } from "vitest";
import { wipeCrdtIndexedDb } from "./idb-wipe";
import { CRDT_IDB_PREFIX } from "./manager";

describe("wipeCrdtIndexedDb", () => {
	afterEach(() => vi.unstubAllGlobals());

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

	it("no-ops when indexedDB.databases is unavailable", async () => {
		vi.stubGlobal("indexedDB", {});
		await expect(wipeCrdtIndexedDb()).resolves.toBeUndefined();
	});
});
