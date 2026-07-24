import { describe, expect, it, vi } from "vitest";
import { CrdtOpError } from "../api/crdt-ops";
import { type CrdtOpChannel, makeCrdtOpSend } from "./op-dispatch";
import type { CrdtOp } from "./op-queue";

function op(kind: CrdtOp["kind"], docId = "n1", path = "a.md"): CrdtOp {
	return { id: `op-${docId}`, kind, docId, payload: { path }, enqueuedAt: 0, attempts: 0 };
}

function chan(over: Partial<CrdtOpChannel> = {}): CrdtOpChannel {
	return {
		crdtCreate: vi.fn(async (docId: string) => docId),
		crdtDelete: vi.fn(async (docId: string) => ({ doc_id: docId })),
		...over,
	};
}

describe("makeCrdtOpSend — success", () => {
	it("create → ok, resolves onCreated with the authoritative server id (adopt)", async () => {
		const onCreated = vi.fn();
		const ch = chan({ crdtCreate: vi.fn(async () => "server-id") });
		const send = makeCrdtOpSend({ channel: () => ch, onCreated, onTerminal: vi.fn() });

		expect(await send(op("create", "local-id"))).toBe("ok");
		expect(onCreated).toHaveBeenCalledWith("local-id", "server-id", "a.md");
	});

	it("delete → ok, fires onDeleted", async () => {
		const onDeleted = vi.fn();
		const send = makeCrdtOpSend({
			channel: () => chan(),
			onCreated: vi.fn(),
			onDeleted,
			onTerminal: vi.fn(),
		});
		expect(await send(op("delete"))).toBe("ok");
		expect(onDeleted).toHaveBeenCalledWith("n1");
	});

	it("a post-ack onCreated throw is swallowed — the create still counts as ok", async () => {
		const send = makeCrdtOpSend({
			channel: () => chan(),
			onCreated: vi.fn(async () => {
				throw new Error("body seed failed");
			}),
			onTerminal: vi.fn(),
		});
		expect(await send(op("create"))).toBe("ok");
	});
});

describe("makeCrdtOpSend — no socket", () => {
	it("returns error (hold + retry) when the channel is null", async () => {
		const send = makeCrdtOpSend({ channel: () => null, onCreated: vi.fn(), onTerminal: vi.fn() });
		expect(await send(op("create"))).toBe("error");
	});
});

describe("makeCrdtOpSend — error taxonomy", () => {
	function sendThatRejects(reason: string) {
		const ch = chan({
			crdtCreate: vi.fn(async () => {
				throw new CrdtOpError(reason, "crdt_create");
			}),
		});
		return { ch };
	}

	it("terminal reason → ok (removed) AND onTerminal fires", async () => {
		const onTerminal = vi.fn();
		const { ch } = sendThatRejects("id_conflict");
		const send = makeCrdtOpSend({ channel: () => ch, onCreated: vi.fn(), onTerminal });
		expect(await send(op("create"))).toBe("ok");
		expect(onTerminal).toHaveBeenCalledWith(
			expect.objectContaining({ docId: "n1" }),
			"id_conflict",
		);
	});

	it("limit reason → error (retryable) AND onLimit fires once across retries", async () => {
		const onLimit = vi.fn();
		const { ch } = sendThatRejects("notes_cap_reached");
		const send = makeCrdtOpSend({
			channel: () => ch,
			onCreated: vi.fn(),
			onTerminal: vi.fn(),
			onLimit,
		});
		const o = op("create");
		expect(await send(o)).toBe("error");
		expect(await send(o)).toBe("error"); // retry
		expect(onLimit).toHaveBeenCalledTimes(1); // surfaced once per op
	});

	it("timeout reason → timeout (retryable)", async () => {
		const { ch } = sendThatRejects("timeout");
		const send = makeCrdtOpSend({ channel: () => ch, onCreated: vi.fn(), onTerminal: vi.fn() });
		expect(await send(op("create"))).toBe("timeout");
	});

	it("unknown/transient reason (rate_limited) → error (retryable)", async () => {
		const { ch } = sendThatRejects("rate_limited");
		const send = makeCrdtOpSend({ channel: () => ch, onCreated: vi.fn(), onTerminal: vi.fn() });
		expect(await send(op("create"))).toBe("error");
	});
});
