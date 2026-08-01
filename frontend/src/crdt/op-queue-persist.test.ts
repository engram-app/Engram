import "fake-indexeddb/auto";
import { beforeEach, describe, expect, it } from "vitest";
import type { CrdtOp } from "./op-queue";
import { createIndexedDbPersister } from "./op-queue-persist";

function op(docId: string): CrdtOp {
	return {
		id: `op-${docId}`,
		kind: "create",
		docId,
		payload: { path: `${docId}.md` },
		enqueuedAt: 1,
		attempts: 0,
	};
}

// Fresh DB per test so state never bleeds.
beforeEach(async () => {
	await new Promise<void>((resolve) => {
		const req = indexedDB.deleteDatabase("engram-crdt-queue");
		req.onsuccess = () => resolve();
		req.onerror = () => resolve();
		req.onblocked = () => resolve();
	});
});

describe("createIndexedDbPersister", () => {
	it("round-trips a saved op list", async () => {
		const p = createIndexedDbPersister("u1", "v1");
		expect(await p.load()).toEqual([]); // empty to start
		await p.save([op("a"), op("b")]);
		expect(await p.load()).toEqual([op("a"), op("b")]);
	});

	it("scopes by (user, vault) — a different vault sees its own queue", async () => {
		const p1 = createIndexedDbPersister("u1", "v1");
		const p2 = createIndexedDbPersister("u1", "v2");
		await p1.save([op("a")]);
		await p2.save([op("z")]);
		expect(await p1.load()).toEqual([op("a")]);
		expect(await p2.load()).toEqual([op("z")]);
	});

	it("saving an empty list clears the key (no residue)", async () => {
		const p = createIndexedDbPersister("u1", "v1");
		await p.save([op("a")]);
		await p.save([]);
		expect(await p.load()).toEqual([]);
	});

	it("clear() removes the persisted queue", async () => {
		const p = createIndexedDbPersister("u1", "v1");
		await p.save([op("a")]);
		await p.clear();
		expect(await p.load()).toEqual([]);
	});
});
