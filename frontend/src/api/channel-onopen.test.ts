import { afterEach, describe, expect, it, vi } from "vitest";

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

import { connectChannel, disconnectChannel } from "./channel";

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
});
