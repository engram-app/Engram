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

describe("connectChannel onSocketOpen", () => {
	it("registers onSocketOpen with the socket so reconnects can fire it", async () => {
		const onSocketOpen = vi.fn();
		const queryClient = { invalidateQueries: vi.fn() } as never;

		await connectChannel({
			userId: "u1",
			vaultId: "v1",
			getToken: async () => "t",
			queryClient,
			onSocketOpen,
		});

		expect(onOpen).toHaveBeenCalledTimes(1);
		const registered = onOpen.mock.calls[0]![0] as () => void;
		registered();
		expect(onSocketOpen).toHaveBeenCalledTimes(1);
	});

	// Folder markers no longer ride the /sync/changes feed (backend #976 excludes
	// kind=="folder" — they crashed pre-#216 plugins). An offline tab therefore
	// misses an empty-folder delete: it produces no descendant note rows, so the
	// catch-up pull carries nothing to invalidate ["folders"]. Reconcile the
	// folder snapshot on every (re)connect instead, matching the plugin's
	// snapshot-diff approach. Regression guard for tree-ops-sync.spec.ts:487.
	it("invalidates the folders snapshot on (re)connect so missed empty-folder deletes converge", async () => {
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
	});
});
