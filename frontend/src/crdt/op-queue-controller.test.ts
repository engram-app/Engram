import { describe, expect, it, vi } from "vitest";
import { CrdtOpError } from "../api/crdt-ops";
import type { CrdtOpChannel } from "./op-dispatch";
import type { CrdtOp } from "./op-queue";
import { CrdtOpQueueController, type CrdtOpQueueControllerDeps } from "./op-queue-controller";
import type { Persister } from "./op-queue-persist";

const memPersister = (): Persister => {
	let ops: CrdtOp[] = [];
	return {
		load: async () => ops,
		save: async (o) => {
			ops = o;
		},
		clear: async () => {
			ops = [];
		},
	};
};

let idc = 0;
function makeController(over: Partial<CrdtOpQueueControllerDeps> = {}) {
	idc = 0;
	const remapId = vi.fn();
	const onDropSurfaced = vi.fn();
	const onLimitSurfaced = vi.fn();
	const ctrl = new CrdtOpQueueController({
		channel: over.channel ?? (() => okChannel),
		remapId,
		onDropSurfaced,
		onLimitSurfaced,
		persister: over.persister ?? memPersister(),
		mintId: () => `op-${++idc}`,
		now: () => 1000,
		tickMs: 1_000_000, // never auto-tick; drive via joined()/enqueue kick
		queueOptions: over.queueOptions,
	});
	return { ctrl, remapId, onDropSurfaced, onLimitSurfaced };
}

const okChannel: CrdtOpChannel = {
	crdtCreate: async (docId: string) => docId, // echoes id (no adopt)
	crdtDelete: async (docId: string) => ({ doc_id: docId }),
};

describe("CrdtOpQueueController — settlement", () => {
	it("holds a create until joined, then resolves with the server id", async () => {
		const { ctrl } = makeController();
		const p = ctrl.enqueueCreate("a", "a.md");
		expect(ctrl.size()).toBe(1); // held — not joined
		let settled = false;
		p.then(() => {
			settled = true;
		});
		await Promise.resolve();
		expect(settled).toBe(false);

		await ctrl.joined();
		await expect(p).resolves.toBe("a");
		expect(ctrl.size()).toBe(0);
	});

	it("remaps the cache id and resolves with the server id on ADOPT", async () => {
		const adoptChannel: CrdtOpChannel = {
			crdtCreate: async () => "server-adopted",
			crdtDelete: async (d) => ({ doc_id: d }),
		};
		const { ctrl, remapId } = makeController({ channel: () => adoptChannel });
		await ctrl.joined();
		await expect(ctrl.enqueueCreate("local", "a.md")).resolves.toBe("server-adopted");
		expect(remapId).toHaveBeenCalledWith("local", "server-adopted");
	});

	it("resolves a delete once acked", async () => {
		const { ctrl } = makeController();
		await ctrl.joined();
		await expect(ctrl.enqueueDelete("a")).resolves.toEqual({ doc_id: "a" });
	});

	it("rejects with the server reason on a terminal failure and surfaces it", async () => {
		const terminalChannel: CrdtOpChannel = {
			crdtCreate: async () => {
				throw new CrdtOpError("id_conflict", "crdt_create");
			},
			crdtDelete: async (d) => ({ doc_id: d }),
		};
		const { ctrl, onDropSurfaced } = makeController({ channel: () => terminalChannel });
		await ctrl.joined();
		await expect(ctrl.enqueueCreate("a", "a.md")).rejects.toMatchObject({ reason: "id_conflict" });
		expect(onDropSurfaced).toHaveBeenCalledWith(
			expect.objectContaining({ docId: "a" }),
			"terminal",
		);
	});

	it("rejects the prior caller as superseded when a newer op replaces it", async () => {
		const { ctrl } = makeController();
		const create = ctrl.enqueueCreate("a", "a.md"); // held (not joined)
		const del = ctrl.enqueueDelete("a"); // supersedes the create
		await expect(create).rejects.toMatchObject({ reason: "superseded" });
		await ctrl.joined();
		await expect(del).resolves.toEqual({ doc_id: "a" });
	});

	it("rejects a dropped op (overflow) and surfaces the drop", async () => {
		const { ctrl, onDropSurfaced } = makeController({ queueOptions: { maxQueue: 1 } });
		const first = ctrl.enqueueCreate("a", "a.md"); // held
		const second = ctrl.enqueueCreate("b", "b.md"); // overflow → evicts "a"
		await expect(first).rejects.toMatchObject({ reason: "overflow" });
		expect(onDropSurfaced).toHaveBeenCalledWith(
			expect.objectContaining({ docId: "a" }),
			"overflow",
		);
		// second still deliverable
		await ctrl.joined();
		await expect(second).resolves.toBe("b");
	});

	it("surfaces a plan-limit reject once and keeps the op pending (retryable)", async () => {
		const limitChannel: CrdtOpChannel = {
			crdtCreate: async () => {
				throw new CrdtOpError("notes_cap_reached", "crdt_create");
			},
			crdtDelete: async (d) => ({ doc_id: d }),
		};
		const { ctrl, onLimitSurfaced } = makeController({ channel: () => limitChannel });
		await ctrl.joined();
		const p = ctrl.enqueueCreate("a", "a.md");
		let settled = false;
		p.then(
			() => {
				settled = true;
			},
			() => {
				settled = true;
			},
		);
		await Promise.resolve();
		expect(settled).toBe(false); // still pending — will retry
		expect(onLimitSurfaced).toHaveBeenCalledWith(
			expect.objectContaining({ docId: "a" }),
			"notes_cap_reached",
		);
		expect(ctrl.size()).toBe(1);
	});

	it("stop() rejects still-pending callers as disconnected", async () => {
		const { ctrl } = makeController();
		const p = ctrl.enqueueCreate("a", "a.md"); // held
		ctrl.stop();
		await expect(p).rejects.toMatchObject({ reason: "disconnected" });
	});

	it("start() restores persisted ops", async () => {
		const persister = memPersister();
		await persister.save([
			{
				id: "op-x",
				kind: "create",
				docId: "x",
				payload: { path: "x.md" },
				enqueuedAt: 1000,
				attempts: 0,
			},
		]);
		const { ctrl } = makeController({ persister });
		await ctrl.start();
		expect(ctrl.size()).toBe(1);
		await ctrl.joined();
		expect(ctrl.size()).toBe(0); // delivered
		ctrl.stop();
	});
});
