import { describe, expect, it, vi } from "vitest";
import {
	CrdtOpError,
	pushRequest,
	sendCrdtCreate,
	sendCrdtCreateBatch,
	sendCrdtDelete,
} from "./crdt-ops";

// Minimal phoenix Channel.push mock: push(event, payload) → a Push whose
// .receive(status, cb) fires cb synchronously when status matches `reply`,
// and is chainable. `reply` picks which branch (ok/error/timeout) fires.
function mockChannel(reply: { status: "ok" | "error" | "timeout"; response?: unknown }) {
	const push = vi.fn((_event: string, _payload: unknown) => {
		const p = {
			receive: (status: string, cb: (resp?: unknown) => void) => {
				if (status === reply.status) {
					cb(reply.response);
				}
				return p;
			},
		};
		return p;
	});
	return { push, channel: { push } as never };
}

describe("pushRequest", () => {
	it("resolves with the ok response", async () => {
		const { channel } = mockChannel({ status: "ok", response: { doc_id: "n1" } });
		await expect(
			pushRequest(channel, "crdt_create", { doc_id: "n1", path: "a.md" }),
		).resolves.toEqual({ doc_id: "n1" });
	});

	it("rejects with a CrdtOpError carrying the server reason on an error reply", async () => {
		const { channel } = mockChannel({ status: "error", response: { reason: "notes_cap_reached" } });
		await expect(pushRequest(channel, "crdt_create", {})).rejects.toMatchObject({
			reason: "notes_cap_reached",
		});
		await expect(pushRequest(channel, "crdt_create", {})).rejects.toBeInstanceOf(CrdtOpError);
	});

	it("rejects on timeout", async () => {
		const { channel } = mockChannel({ status: "timeout" });
		await expect(pushRequest(channel, "crdt_delete", {})).rejects.toThrow(/timeout/i);
	});

	it("rejects immediately with reason 'disconnected' when the channel is null (not joined)", async () => {
		await expect(pushRequest(null, "crdt_create", {})).rejects.toMatchObject({
			reason: "disconnected",
		});
	});
});

describe("sendCrdtCreate", () => {
	it("pushes crdt_create with doc_id+path and returns the authoritative doc_id", async () => {
		const { channel, push } = mockChannel({ status: "ok", response: { doc_id: "n1" } });
		const id = await sendCrdtCreate(channel, "n1", "folder/a.md");
		expect(push).toHaveBeenCalledWith("crdt_create", { doc_id: "n1", path: "folder/a.md" });
		expect(id).toBe("n1");
	});

	it("returns the server's ADOPTED id when it differs from the minted one", async () => {
		const { channel } = mockChannel({ status: "ok", response: { doc_id: "server-owned" } });
		const id = await sendCrdtCreate(channel, "minted-id", "a.md");
		expect(id).toBe("server-owned");
	});
});

describe("sendCrdtDelete", () => {
	it("pushes crdt_delete with doc_id and resolves on ack", async () => {
		const { channel, push } = mockChannel({ status: "ok", response: { doc_id: "n1" } });
		await expect(sendCrdtDelete(channel, "n1")).resolves.toEqual({ doc_id: "n1" });
		expect(push).toHaveBeenCalledWith("crdt_delete", { doc_id: "n1" });
	});
});

describe("sendCrdtCreateBatch", () => {
	it("pushes crdt_create_batch with the creates list and returns results", async () => {
		const creates = [{ doc_id: "n1", path: "a.md", b64: "AAA" }];
		const { channel, push } = mockChannel({
			status: "ok",
			response: { results: [{ doc_id: "n1", status: "ok" }] },
		});
		const res = await sendCrdtCreateBatch(channel, creates);
		expect(push).toHaveBeenCalledWith("crdt_create_batch", { creates });
		expect(res.results[0]).toEqual({ doc_id: "n1", status: "ok" });
	});
});
