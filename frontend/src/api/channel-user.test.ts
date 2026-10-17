import { afterEach, describe, expect, it, vi } from "vitest";
import { englishT } from "@/i18n/translate";
import { connectChannel, disconnectChannel, subscribeUserChannel } from "./channel";

// The user:{id} channel rides the tab's one Phoenix socket: the sync socket
// when a vault is open, or a socket of its own before there is one (first
// run), never both.

interface MockChannel {
	topic: string;
	on: ReturnType<typeof vi.fn>;
	handlers: Record<string, (payload: unknown) => void>;
	join: ReturnType<typeof vi.fn>;
	leave: ReturnType<typeof vi.fn>;
	joinOk: () => void;
}

interface MockSocket {
	connect: ReturnType<typeof vi.fn>;
	disconnect: ReturnType<typeof vi.fn>;
	isConnected: ReturnType<typeof vi.fn>;
	onOpen: ReturnType<typeof vi.fn>;
	onError: ReturnType<typeof vi.fn>;
	channel: ReturnType<typeof vi.fn>;
	channels: MockChannel[];
	disconnected: boolean;
}

const { socketCtor, sockets } = vi.hoisted(() => {
	const sockets: MockSocket[] = [];
	const socketCtor = vi.fn(function MockSocket(this: MockSocket) {
		this.channels = [];
		this.disconnected = false;
		this.connect = vi.fn();
		this.disconnect = vi.fn((cb?: () => void) => {
			this.disconnected = true;
			cb?.();
		});
		this.isConnected = vi.fn(() => true);
		this.onOpen = vi.fn();
		this.onError = vi.fn();
		this.channel = vi.fn((topic: string) => {
			let ok: () => void = () => {};
			const handlers: Record<string, (payload: unknown) => void> = {};
			const ch: MockChannel = {
				topic,
				handlers,
				on: vi.fn((event: string, cb: (payload: unknown) => void) => {
					handlers[event] = cb;
				}),
				leave: vi.fn(),
				joinOk: () => ok(),
				join: vi.fn(() => {
					const push = {
						receive: (status: string, cb: () => void) => {
							if (status === "ok") {
								ok = cb;
							}
							return push;
						},
					};
					return push;
				}),
			};
			this.channels.push(ch);
			return ch;
		});
		sockets.push(this);
	});
	return { socketCtor, sockets };
});

vi.mock("phoenix", () => ({ Socket: socketCtor, Channel: vi.fn() }));

const queryClient = { invalidateQueries: vi.fn() } as never;
const getToken = async () => "tok";
const live = () => sockets.filter((s) => !s.disconnected);
const userChannels = (s: MockSocket) => s.channels.filter((c) => c.topic === "user:u1");

afterEach(() => {
	disconnectChannel();
	sockets.length = 0;
	vi.clearAllMocks();
});

describe("user channel", () => {
	it("joins on the sync socket instead of opening another", async () => {
		await connectChannel({ userId: "u1", vaultId: "v1", getToken, queryClient, t: englishT });
		const off = await subscribeUserChannel(
			{ userId: "u1", getToken },
			"connection_created",
			vi.fn(),
		);

		expect(sockets).toHaveLength(1);
		expect(userChannels(sockets[0]!)).toHaveLength(1);
		off();
	});

	it("opens one socket before a vault exists, then moves onto the sync socket", async () => {
		const handler = vi.fn();
		const off = await subscribeUserChannel({ userId: "u1", getToken }, "vault_created", handler);
		expect(live()).toHaveLength(1);

		await connectChannel({ userId: "u1", vaultId: "v1", getToken, queryClient, t: englishT });

		expect(live()).toHaveLength(1);
		const now = live()[0]!;
		const [ch] = userChannels(now);
		expect(ch).toBeDefined();
		ch!.handlers.vault_created?.({ vault_id: "v1" });
		expect(handler).toHaveBeenCalledWith({ vault_id: "v1" });
		off();
	});

	it("shares one user channel between subscribers", async () => {
		const offA = await subscribeUserChannel({ userId: "u1", getToken }, "a", vi.fn());
		const offB = await subscribeUserChannel({ userId: "u1", getToken }, "b", vi.fn());
		expect(live()).toHaveLength(1);
		expect(userChannels(live()[0]!)).toHaveLength(1);
		offA();
		offB();
	});

	// An event broadcast before this tab joined is lost; a subscriber that
	// must not miss one re-reads its data on every (re)join instead.
	it("tells subscribers when the channel joins", async () => {
		const onJoined = vi.fn();
		const off = await subscribeUserChannel(
			{ userId: "u1", getToken },
			"connection_created",
			vi.fn(),
			onJoined,
		);
		userChannels(live()[0]!)[0]!.joinOk();
		expect(onJoined).toHaveBeenCalledTimes(1);
		off();
	});

	// #531: a getToken that rejects must not leave the handler registered.
	it("drops the subscription when getToken rejects", async () => {
		const fail = () => Promise.reject(new Error("auth not ready"));
		await expect(
			subscribeUserChannel({ userId: "u1", getToken: fail }, "a", vi.fn()),
		).rejects.toThrow();
		const off = await subscribeUserChannel({ userId: "u1", getToken }, "b", vi.fn());
		off();
		expect(live()).toHaveLength(0);
		expect(sockets).toHaveLength(1);
		expect(userChannels(sockets[0]!)[0]!.on).not.toHaveBeenCalledWith("a", expect.any(Function));
	});

	it("closes its own socket when the last subscriber leaves", async () => {
		const off = await subscribeUserChannel({ userId: "u1", getToken }, "a", vi.fn());
		off();
		expect(live()).toHaveLength(0);
	});
});
