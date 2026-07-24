import { afterEach, describe, expect, it, vi } from "vitest";
import { connectChannel, crdtCreateNote, crdtDeleteNote, disconnectChannel } from "./channel";

// Phoenix mock that distinguishes the crdt channel (joined with { crdt_proto: 2 })
// so the test can drive its join outcome and capture its push. vi.hoisted +
// constructor function so `new Socket(...)` works.
const h = vi.hoisted(() => {
	const crdtPush = vi.fn();
	const joins: { ok?: (r?: unknown) => void; error?: (r?: unknown) => void } = {};
	const socketCtor = vi.fn(function MockSocket(this: object) {
		Object.assign(this, {
			connect: vi.fn(),
			disconnect: vi.fn(),
			onError: vi.fn(),
			onOpen: vi.fn(),
			isConnected: () => true,
			channel: vi.fn((_topic: string, params?: { crdt_proto?: number }) => {
				const isCrdt = params?.crdt_proto === 2;
				return {
					on: vi.fn(),
					leave: vi.fn(),
					push: isCrdt
						? crdtPush
						: vi.fn(() => ({
								receive() {
									return this;
								},
							})),
					join: vi.fn(() => ({
						receive(status: string, cb: (r?: unknown) => void) {
							if (isCrdt && status === "ok") {
								joins.ok = cb;
							}
							if (isCrdt && status === "error") {
								joins.error = cb;
							}
							return this;
						},
					})),
				};
			}),
		});
	});
	return { crdtPush, joins, socketCtor };
});

vi.mock("phoenix", () => ({ Socket: h.socketCtor, Channel: vi.fn() }));

afterEach(() => {
	disconnectChannel();
	h.crdtPush.mockReset();
	h.joins.ok = undefined;
	h.joins.error = undefined;
});

const opts = {
	userId: "u1",
	vaultId: "v1",
	getToken: async () => "t",
	queryClient: { invalidateQueries: vi.fn() } as never,
};

describe("crdtCreateNote / crdtDeleteNote — offline gate", () => {
	it("pushes crdt_create over the joined channel and returns the doc_id", async () => {
		await connectChannel(opts);
		h.joins.ok?.(); // crdt channel joined → sync status "synced"
		h.crdtPush.mockReturnValue({
			receive(status: string, cb: (r?: unknown) => void) {
				if (status === "ok") {
					cb({ doc_id: "n1" });
				}
				return this;
			},
		});

		await expect(crdtCreateNote("n1", "folder/a.md")).resolves.toBe("n1");
		expect(h.crdtPush).toHaveBeenCalledWith("crdt_create", { doc_id: "n1", path: "folder/a.md" });
	});

	it("rejects create/delete without pushing when the channel is not joined", async () => {
		await connectChannel(opts);
		h.joins.error?.({}); // crdt channel join failed → sync status "error"

		await expect(crdtDeleteNote("n1")).rejects.toThrow(/not joined|disconnect/i);
		expect(h.crdtPush).not.toHaveBeenCalled();
	});
});
