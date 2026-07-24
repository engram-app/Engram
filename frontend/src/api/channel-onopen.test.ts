import { afterEach, describe, expect, it, vi } from "vitest";
import { connectChannel, disconnectChannel } from "./channel";

// Minimal phoenix mock: capture the onOpen callback and the channel handlers.
// Uses vi.hoisted + a constructor function (not arrow) so `new Socket(...)` works.
const {
	onOpen,
	channelOn: _channelOn,
	join: _join,
	socketCtor,
} = vi.hoisted(() => {
	const onOpen = vi.fn();
	const channelOn = vi.fn();
	const join = vi.fn(() => ({ receive: () => ({ receive: () => {} }) }));
	const socketCtor = vi.fn(function MockSocket(this: object) {
		Object.assign(this, {
			connect: vi.fn(),
			disconnect: vi.fn(),
			onError: vi.fn(),
			onOpen,
			channel: vi.fn(() => ({ on: channelOn, join, leave: vi.fn() })),
		});
	});
	return { onOpen, channelOn, join, socketCtor };
});

vi.mock("phoenix", () => ({
	Socket: socketCtor,
	Channel: vi.fn(),
}));

afterEach(() => {
	disconnectChannel();
	vi.clearAllMocks();
});

describe("connectChannel onOpen — structural backfill", () => {
	// The socket drops events while disconnected (no replay), so a reconnect must
	// reconcile everything a backgrounded/offline tab could have missed. The web
	// has no local mirror — reconciling = invalidating the react-query caches so
	// they refetch current state. This replaced the deleted /sync/changes cursor
	// feed (backend #1036): folder markers never rode that feed anyway (#976), and
	// note/attachment structural changes are covered the same snapshot-diff way.
	it("invalidates folders, folderNotes, folder-notes-by-id, and attachments on (re)connect", async () => {
		const invalidateQueries = vi.fn();
		const queryClient = { invalidateQueries } as never;

		await connectChannel({
			userId: "u1",
			vaultId: "v1",
			getToken: async () => "t",
			queryClient,
		});

		const registered = onOpen.mock.calls[0]![0] as () => void;
		registered();

		expect(invalidateQueries).toHaveBeenCalledWith({ queryKey: ["folders", "v1"] });
		expect(invalidateQueries).toHaveBeenCalledWith({ queryKey: ["folderNotes", "v1"] });
		expect(invalidateQueries).toHaveBeenCalledWith({ queryKey: ["attachments", "v1"] });
		// The sidebar tree renders note rows from the id-keyed family, and its
		// expanded-but-observer-less subfolders only refetch under refetchType
		// "all" (matching flushBatch). Missing this = stale tree membership after
		// a sleep/offline catch-up until a full reload.
		expect(invalidateQueries).toHaveBeenCalledWith({
			queryKey: ["folder-notes-by-id", "v1"],
			refetchType: "all",
		});
	});
});
