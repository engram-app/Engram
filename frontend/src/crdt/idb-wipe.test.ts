import { afterEach, describe, expect, it, vi } from "vitest";
import { wipeCrdtIndexedDb } from "./idb-wipe";
import { CRDT_IDB_PREFIX } from "./manager";

describe("wipeCrdtIndexedDb", () => {
	afterEach(() => {
		vi.unstubAllGlobals();
		vi.useRealTimers();
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

	it("no-ops when indexedDB.databases is unavailable", async () => {
		vi.stubGlobal("indexedDB", {});
		await expect(wipeCrdtIndexedDb()).resolves.toBeUndefined();
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
