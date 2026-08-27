import { afterEach, describe, expect, it, vi } from "vitest";
import {
	connectChannel,
	crdtCreateNote,
	crdtCreateNoteWithContent,
	crdtDeleteNote,
	disconnectChannel,
} from "./channel";

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

	it("HOLDS a delete while not joined, then delivers it on join (durable, not dropped)", async () => {
		// Durable op queue (#1030): a terminal op issued before the topic is joined
		// is buffered and flushed on join — NOT rejected/dropped like the old
		// reject-fast gate.
		await connectChannel(opts);
		h.joins.error?.({}); // crdt channel join failed → sync status "error"
		h.crdtPush.mockReturnValue({
			receive(status: string, cb: (r?: unknown) => void) {
				if (status === "ok") {
					cb({ doc_id: "n1" });
				}
				return this;
			},
		});

		const p = crdtDeleteNote("n1");
		await Promise.resolve();
		expect(h.crdtPush).not.toHaveBeenCalled(); // held — not joined

		h.joins.ok?.(); // topic joins → queue flushes held ops
		await expect(p).resolves.toEqual({ doc_id: "n1" });
		expect(h.crdtPush).toHaveBeenCalledWith("crdt_delete", { doc_id: "n1" });
	});
});

describe("crdtCreateNoteWithContent — adopt detection (occupied path)", () => {
	const createReply = (reply: { doc_id: string; genesis: string }) => ({
		receive(status: string, cb: (r?: unknown) => void) {
			if (status === "ok") {
				cb(reply);
			}
			return this;
		},
	});

	it("returns the doc_id when the server CREATES our note (id echoed back)", async () => {
		await connectChannel(opts);
		h.joins.ok?.();
		h.crdtPush.mockReturnValue(createReply({ doc_id: "minted-new", genesis: "stored" }));

		await expect(crdtCreateNoteWithContent("minted-new", "folder/copy.md", "# copy")).resolves.toBe(
			"minted-new",
		);
		expect(h.crdtPush).toHaveBeenCalledWith(
			"crdt_create",
			expect.objectContaining({ doc_id: "minted-new", path: "folder/copy.md" }),
		);
	});

	it("throws create_failed when the server ADOPTS a different note (occupied path)", async () => {
		await connectChannel(opts);
		h.joins.ok?.();
		// Path already held by another live note → backend genesis_adopt_or_insert
		// returns {:ok, live} with the OCCUPANT's id, never seeding our content.
		h.crdtPush.mockReturnValue(createReply({ doc_id: "existing-occupant", genesis: "occupied" }));

		await expect(
			crdtCreateNoteWithContent("minted-new", "folder/taken.md", "# copy"),
		).rejects.toMatchObject({ reason: "create_failed" });
	});

	// Our id came back, so the ROW is ours — but the server declined to seed the
	// body (the roomless genesis refuses a non-markdown path, since projecting a
	// markdown body over a canvas would erase the board). The retired
	// crdt_create_batch reported `status: "ok"` here and the caller saved a
	// silently EMPTY duplicate; the outcome has to reach the caller instead.
	it("throws when the row is ours but the body was NOT seeded", async () => {
		await connectChannel(opts);
		h.joins.ok?.();
		h.crdtPush.mockReturnValue(createReply({ doc_id: "minted-new", genesis: "absent" }));

		await expect(
			crdtCreateNoteWithContent("minted-new", "folder/board.canvas", "# copy"),
		).rejects.toMatchObject({ reason: "not_seeded" });
	});
});
