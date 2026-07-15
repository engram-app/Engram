import { afterEach, describe, expect, it, vi } from "vitest";
import { connectChannel, disconnectChannel } from "./channel";

// connectChannel runs disconnectChannel() then `await getToken()` before it
// assigns the module singletons. Two callers (the mount effect + the new
// wake-reconnect trigger) can interleave across that await. These tests pin
// that a connect superseded during its token fetch does NOT build a socket.
const { socketCtor } = vi.hoisted(() => {
	const socketCtor = vi.fn(function MockSocket(this: object) {
		Object.assign(this, {
			connect: vi.fn(),
			disconnect: vi.fn(),
			onError: vi.fn(),
			onOpen: vi.fn(),
			channel: vi.fn(() => ({
				on: vi.fn(),
				join: vi.fn(() => ({ receive: () => ({ receive: () => {} }) })),
				leave: vi.fn(),
			})),
		});
	});
	return { socketCtor };
});

vi.mock("phoenix", () => ({ Socket: socketCtor, Channel: vi.fn() }));

const queryClient = { invalidateQueries: vi.fn() } as never;

afterEach(() => {
	disconnectChannel();
	vi.clearAllMocks();
});

describe("connectChannel re-entrancy", () => {
	it("does not build a socket when superseded during the token fetch", async () => {
		let releaseToken!: (t: string) => void;
		const p = connectChannel({
			userId: "u1",
			vaultId: "v1",
			getToken: () =>
				new Promise<string>((r) => {
					releaseToken = r;
				}),
			queryClient,
		});

		// A vault switch / teardown tears down while the token is still in flight.
		disconnectChannel();
		releaseToken("t");
		await p;

		expect(socketCtor).not.toHaveBeenCalled();
	});

	it("only the latest connect builds a socket when two race", async () => {
		let release1!: (t: string) => void;
		let release2!: (t: string) => void;
		const p1 = connectChannel({
			userId: "u1",
			vaultId: "v1",
			getToken: () =>
				new Promise<string>((r) => {
					release1 = r;
				}),
			queryClient,
		});
		const p2 = connectChannel({
			userId: "u1",
			vaultId: "v2",
			getToken: () =>
				new Promise<string>((r) => {
					release2 = r;
				}),
			queryClient,
		});

		release1("t1");
		release2("t2");
		await Promise.all([p1, p2]);

		expect(socketCtor).toHaveBeenCalledTimes(1);
	});
});
