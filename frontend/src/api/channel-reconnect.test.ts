import { afterEach, describe, expect, it, vi } from "vitest";
import { connectChannel, disconnectChannel, reconnectWithFreshToken } from "./channel";

// The socket is built with a params FUNCTION (phoenix re-evaluates it on every
// (re)connect) backed by a refreshable token, so a reconnect after a long idle
// re-authenticates instead of replaying an expired token. reconnectWithFreshToken
// refreshes that token and reconnects the transport IN PLACE — no new Socket, no
// CRDT-session teardown — so an open editor's Y.Doc is never destroyed.

interface MockSocket {
	opts: { params: () => { token: string } };
	connect: ReturnType<typeof vi.fn>;
	disconnect: ReturnType<typeof vi.fn>;
	isConnected: ReturnType<typeof vi.fn>;
	onOpen: ReturnType<typeof vi.fn>;
	onError: ReturnType<typeof vi.fn>;
	channel: ReturnType<typeof vi.fn>;
}

const { socketCtor, sockets } = vi.hoisted(() => {
	const sockets: MockSocket[] = [];
	const socketCtor = vi.fn(function MockSocket(this: MockSocket, _url: string, opts: never) {
		this.opts = opts;
		this.connect = vi.fn();
		// phoenix calls the disconnect callback once teardown completes.
		this.disconnect = vi.fn((cb?: () => void) => cb?.());
		this.isConnected = vi.fn(() => true);
		this.onOpen = vi.fn();
		this.onError = vi.fn();
		this.channel = vi.fn(() => ({
			on: vi.fn(),
			join: vi.fn(() => ({ receive: () => ({ receive: () => {} }) })),
			leave: vi.fn(),
		}));
		sockets.push(this);
	});
	return { socketCtor, sockets };
});

vi.mock("phoenix", () => ({ Socket: socketCtor, Channel: vi.fn() }));

const queryClient = { invalidateQueries: vi.fn() } as never;

afterEach(() => {
	disconnectChannel();
	sockets.length = 0;
	vi.clearAllMocks();
});

describe("token refresh on reconnect", () => {
	it("builds the socket with a params function returning the fetched token", async () => {
		await connectChannel({
			userId: "u1",
			vaultId: "v1",
			getToken: async () => "tok-A",
			queryClient,
		});

		expect(typeof sockets[0]!.opts.params).toBe("function");
		expect(sockets[0]!.opts.params()).toEqual({ token: "tok-A" });
	});

	it("refreshes the token the params function returns, on the SAME socket", async () => {
		await connectChannel({
			userId: "u1",
			vaultId: "v1",
			getToken: async () => "tok-A",
			queryClient,
		});
		const socket = sockets[0]!;

		await reconnectWithFreshToken(async () => "tok-B");

		expect(sockets).toHaveLength(1); // no new socket — session preserved
		expect(socket.opts.params()).toEqual({ token: "tok-B" });
	});

	it("reconnects the transport in place (disconnect + connect on the same socket)", async () => {
		await connectChannel({
			userId: "u1",
			vaultId: "v1",
			getToken: async () => "tok-A",
			queryClient,
		});
		const socket = sockets[0]!;

		await reconnectWithFreshToken(async () => "tok-B");

		expect(socket.disconnect).toHaveBeenCalledTimes(1);
		expect(socket.connect).toHaveBeenCalledTimes(2); // initial connect + reconnect
	});

	it("is a no-op when there is no live socket", async () => {
		await reconnectWithFreshToken(async () => "tok-B");
		expect(sockets).toHaveLength(0);
	});

	it("aborts if a teardown supersedes it during the token fetch", async () => {
		await connectChannel({
			userId: "u1",
			vaultId: "v1",
			getToken: async () => "tok-A",
			queryClient,
		});
		const socket = sockets[0]!;

		let release!: (t: string) => void;
		const p = reconnectWithFreshToken(
			() =>
				new Promise<string>((r) => {
					release = r;
				}),
		);
		disconnectChannel(); // vault switch / unmount tears the socket down mid-fetch
		release("tok-B");
		await p;

		// disconnectChannel already called socket.disconnect once; the superseded
		// reconnect must NOT re-connect the now-dead socket.
		expect(socket.connect).toHaveBeenCalledTimes(1); // only the initial connect
	});

	it("does not revive an orphaned socket if a teardown lands during phoenix's async close", async () => {
		await connectChannel({
			userId: "u1",
			vaultId: "v1",
			getToken: async () => "tok-A",
			queryClient,
		});
		const socket = sockets[0]!;

		// Model phoenix's ASYNC teardown: disconnect() stores the callback instead
		// of firing it, so we can interleave a vault switch before close completes.
		// Keep only the reconnect's callback — disconnectChannel's later no-arg
		// disconnect() must not overwrite it.
		const teardown: { done: (() => void) | null } = { done: null };
		socket.disconnect = vi.fn((cb?: () => void) => {
			teardown.done ??= cb ?? (() => {});
		});

		await reconnectWithFreshToken(async () => "tok-B"); // token resolved, disconnect pending
		disconnectChannel(); // vault switch / unmount lands mid-teardown
		teardown.done?.(); // phoenix finishes closing the old conn

		// The reconnect's disconnect callback must NOT connect the orphaned socket.
		expect(socket.connect).toHaveBeenCalledTimes(1); // only the initial connect
	});
});
