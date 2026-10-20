import { afterEach, describe, expect, it, vi } from "vitest";
import { englishT } from "@/i18n/translate";
import { connectChannel, disconnectChannel, onConnectionCreated } from "./channel";

// The connection notice rides the tab's ONE sync socket (fresh-token params,
// onError refresh, jittered backoff), never a socket of its own: a second
// socket with static params replayed an expired Clerk JWT forever.
const { channels, socketCtor } = vi.hoisted(() => {
	const channels: Record<
		string,
		{ handlers: Record<string, (p: unknown) => void>; leave: ReturnType<typeof vi.fn> }
	> = {};
	const socketCtor = vi.fn(function MockSocket(this: object) {
		Object.assign(this, {
			connect: vi.fn(),
			disconnect: vi.fn(),
			onError: vi.fn(),
			onOpen: vi.fn(),
			channel: vi.fn((topic: string) => {
				const handlers: Record<string, (p: unknown) => void> = {};
				const leave = vi.fn();
				channels[topic] = { handlers, leave };
				return {
					on: (event: string, cb: (p: unknown) => void) => {
						handlers[event] = cb;
					},
					join: () => ({ receive: () => ({ receive: () => {} }) }),
					leave,
				};
			}),
		});
	});
	return { channels, socketCtor };
});

vi.mock("phoenix", () => ({ Socket: socketCtor, Channel: vi.fn() }));

const connect = () =>
	connectChannel({
		userId: "u1",
		vaultId: "v1",
		getToken: async () => "t",
		queryClient: { invalidateQueries: vi.fn() } as never,
		t: englishT,
	});

afterEach(() => {
	disconnectChannel();
	vi.clearAllMocks();
	for (const k of Object.keys(channels)) {
		delete channels[k];
	}
});

describe("connection_created on the shared socket", () => {
	it("joins user:{id} on the sync socket, not a second one", async () => {
		await connect();
		expect(socketCtor).toHaveBeenCalledTimes(1);
		expect(channels["user:u1"]).toBeDefined();
	});

	it("hands each event to the subscribers until they unsubscribe", async () => {
		const listener = vi.fn();
		const off = onConnectionCreated(listener);
		await connect();

		channels["user:u1"]?.handlers.connection_created?.({ client_name: "ChatGPT", kind: "mcp" });
		expect(listener).toHaveBeenCalledWith({ client_name: "ChatGPT", kind: "mcp" });

		off();
		channels["user:u1"]?.handlers.connection_created?.({ client_name: "ChatGPT", kind: "mcp" });
		expect(listener).toHaveBeenCalledTimes(1);
	});

	it("leaves the user channel on disconnect", async () => {
		await connect();
		const userChannel = channels["user:u1"];
		disconnectChannel();
		expect(userChannel?.leave).toHaveBeenCalled();
	});
});
