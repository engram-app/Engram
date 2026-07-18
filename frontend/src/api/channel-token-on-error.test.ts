import { afterEach, describe, expect, it, vi } from "vitest";
import { connectChannel, disconnectChannel } from "./channel";

// A socket auth-reject loop replayed one frozen expired token for hours (prod
// 2026-07-15): phoenix re-reads params() per attempt, but latestToken only
// changed on connectChannel/reconnectWithFreshToken, and the health triggers
// (focus/online/visibility) demonstrably don't fire on an unattended — or even
// an actively used — tab. socket.onError is the one signal that fires on every
// failed attempt, so the token now refreshes there.

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

const flush = () => new Promise((r) => setTimeout(r, 0));

afterEach(() => {
	disconnectChannel();
	sockets.length = 0;
	vi.clearAllMocks();
});

describe("token refresh on socket error", () => {
	it("re-fetches the token when a connect attempt errors, so the next retry uses it", async () => {
		let current = "tok-A";
		await connectChannel({
			userId: "u1",
			vaultId: "v1",
			getToken: async () => current,
			queryClient,
		});
		expect(sockets[0]!.opts.params()).toEqual({ token: "tok-A" });
		expect(sockets[0]!.onError).toHaveBeenCalled();

		current = "tok-B";
		const errorCb = sockets[0]!.onError.mock.calls[0]![0] as () => void;
		errorCb();
		await flush();

		expect(sockets[0]!.opts.params()).toEqual({ token: "tok-B" });
	});

	it("keeps the previous token when the refresh itself fails", async () => {
		let fail = false;
		await connectChannel({
			userId: "u1",
			vaultId: "v1",
			getToken: async () => {
				if (fail) {
					throw new Error("clerk down");
				}
				return "tok-A";
			},
			queryClient,
		});

		fail = true;
		const errorCb = sockets[0]!.onError.mock.calls[0]![0] as () => void;
		errorCb();
		await flush();

		expect(sockets[0]!.opts.params()).toEqual({ token: "tok-A" });
	});

	it("a refresh resolving after teardown does not touch the next connection's token", async () => {
		let release: (v: string) => void = () => {};
		let slow = false;
		await connectChannel({
			userId: "u1",
			vaultId: "v1",
			getToken: () =>
				slow
					? new Promise<string>((r) => {
							release = r;
						})
					: Promise.resolve("tok-A"),
			queryClient,
		});
		slow = true;
		const errorCb = sockets[0]!.onError.mock.calls[0]![0] as () => void;
		errorCb(); // refresh now pending on `release`

		disconnectChannel();
		await connectChannel({
			userId: "u1",
			vaultId: "v2",
			getToken: async () => "tok-NEW",
			queryClient,
		});

		release("tok-STALE");
		await flush();
		expect(sockets[1]!.opts.params()).toEqual({ token: "tok-NEW" });
	});
});

describe("stuck refresh flag (review 2026-07-15)", () => {
	it("a getToken hung across a teardown does not block the next connection's refresh", async () => {
		let hang = false;
		await connectChannel({
			userId: "u1",
			vaultId: "v1",
			getToken: () => (hang ? new Promise<string>(() => {}) : Promise.resolve("tok-A")),
			queryClient,
		});
		hang = true;
		(sockets[0]!.onError.mock.calls[0]![0] as () => void)(); // refresh now hangs forever

		disconnectChannel();
		await connectChannel({
			userId: "u1",
			vaultId: "v2",
			getToken: async () => "tok-NEW",
			queryClient,
		});
		let current = "tok-NEW";
		// Swap the getToken result and fire an error on the new socket: without
		// the teardown reset, tokenRefreshInFlight is still true and this
		// refresh is silently skipped — the frozen-token loop all over again.
		current = "tok-NEWER";
		await connectChannel({
			userId: "u1",
			vaultId: "v2",
			getToken: async () => current,
			queryClient,
		});
		(sockets[2]!.onError.mock.calls[0]![0] as () => void)();
		current = "tok-FINAL";
		(sockets[2]!.onError.mock.calls[0]![0] as () => void)();
		await flush();
		expect(sockets[2]!.opts.params().token).not.toBe("tok-A");
		expect(["tok-NEWER", "tok-FINAL"]).toContain(sockets[2]!.opts.params().token);
	});
});
