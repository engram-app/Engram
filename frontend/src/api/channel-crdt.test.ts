import { beforeEach, describe, expect, it, vi } from "vitest";
import { connectChannel, disconnectChannel } from "./channel";

// Mock the phoenix Socket/Channel so we can assert the crdt: topic join +
// inbound event routing without a real WS.
const channels = new Map<string, any>();
const channelParams = new Map<string, any>();
function mkChannel(topic: string, params?: any) {
	const handlers = new Map<string, (p: any) => void>();
	// Capture the receive("error"/"timeout") callbacks registered on the LAST
	// push so a test can fire them and assert the reason-string dispatch.
	const pushReceivers = new Map<string, (resp?: any) => void>();
	const push = vi.fn(() => {
		pushReceivers.clear();
		const ref = {
			receive: (status: string, cb: (resp?: any) => void) => {
				pushReceivers.set(status, cb);
				return ref;
			},
		};
		return ref;
	});
	const ch = {
		topic,
		on: vi.fn((ev: string, cb: (p: any) => void) => handlers.set(ev, cb)),
		push,
		join: vi.fn(() => ({ receive: (_s: string, _cb: any) => ({ receive: () => {} }) })),
		leave: vi.fn(),
		__emit: (ev: string, p: any) => handlers.get(ev)?.(p),
		/** Fire a receive callback registered on the last push. */
		__firePush: (status: string, resp?: any) => pushReceivers.get(status)?.(resp),
	};
	channels.set(topic, ch);
	channelParams.set(topic, params);
	return ch;
}
vi.mock("phoenix", () => ({
	Socket: class {
		connect() {}
		disconnect() {}
		onOpen(_cb: () => void) {}
		onError(_cb: () => void) {}
		channel(topic: string, params?: any) {
			return mkChannel(topic, params);
		}
	},
	Channel: class {},
}));

const sessionMock = vi.hoisted(() => ({
	startCrdtSession: vi.fn(),
	stopCrdtSession: vi.fn(),
	handleFrame: vi.fn().mockResolvedValue(undefined),
	enrollIfLive: vi.fn(),
	notifyCrdtChannelJoined: vi.fn(),
	notifyCrdtChannelError: vi.fn(),
	resyncOpenDocs: vi.fn(),
	scheduleRehandshake: vi.fn(),
}));
vi.mock("../crdt/session", () => sessionMock);

describe("crdt channel wiring", () => {
	beforeEach(() => {
		channels.clear();
		channelParams.clear();
		vi.clearAllMocks();
		disconnectChannel();
	});

	it("joins crdt:{userId}:{vaultId} and starts a session", async () => {
		await connectChannel({
			userId: "u1",
			vaultId: "v1",
			getToken: async () => "tok",
			queryClient: {} as any,
		});
		expect(channels.has("crdt:u1:v1")).toBe(true);
		expect(sessionMock.startCrdtSession).toHaveBeenCalledWith(
			expect.objectContaining({ vaultId: "v1" }),
		);
	});

	// crdt_doc_ready now routes to enrollIfLive (not unconditional enroll) so
	// background notes announced by the server do not materialize Y.Docs on
	// clients that have not opened them. Coverage is preserved: we still verify
	// the event is routed; the guarding logic itself is tested in session.test.ts.
	it("routes crdt_msg → handleFrame and crdt_doc_ready → enrollIfLive by note_id doc_id", async () => {
		await connectChannel({
			userId: "u1",
			vaultId: "v1",
			getToken: async () => "tok",
			queryClient: {} as any,
		});
		const ch = channels.get("crdt:u1:v1");
		ch.__emit("crdt_msg", { doc_id: "note-uuid-1", b64: "Zm9v" });
		ch.__emit("crdt_doc_ready", { doc_id: "note-uuid-1" });
		// doc_id IS the note_id now — no path splitting.
		expect(sessionMock.handleFrame).toHaveBeenCalledWith("note-uuid-1", "Zm9v");
		expect(sessionMock.enrollIfLive).toHaveBeenCalledWith("note-uuid-1");
	});

	it("joins the CRDT channel with crdt_proto: 2", async () => {
		await connectChannel({
			userId: "u1",
			vaultId: "v1",
			getToken: async () => "tok",
			queryClient: {} as any,
		});
		expect(channelParams.get("crdt:u1:v1")).toEqual({ crdt_proto: 2 });
	});

	// The crdt_msg push's receive("error"/"timeout") branches map server reason
	// strings to a recovery action. A typo in "frame_too_large" would route
	// oversized frames into scheduleRehandshake = an infinite resend loop, so
	// lock the exact dispatch here.
	describe("crdt_msg push reason dispatch", () => {
		const DOC = "note-uuid-2";

		async function connectAndPush() {
			await connectChannel({
				userId: "u1",
				vaultId: "v1",
				getToken: async () => "tok",
				queryClient: {} as any,
			});
			const ch = channels.get("crdt:u1:v1");
			// Invoke the push closure the session was given so it registers its
			// receive("error"/"timeout") callbacks on the CRDT channel push mock.
			const push = sessionMock.startCrdtSession.mock.calls.at(-1)![0].push as (
				docId: string,
				b64: string,
			) => void;
			push(DOC, "Zm9v");
			return ch;
		}

		it("error {reason:'rate_limited'} → rehandshake after 2000ms", async () => {
			const ch = await connectAndPush();
			ch.__firePush("error", { reason: "rate_limited" });
			expect(sessionMock.scheduleRehandshake).toHaveBeenCalledWith(DOC, 2000);
		});

		it("error {reason:'frame_too_large'} → NO rehandshake, logs error", async () => {
			const spy = vi.spyOn(console, "error").mockImplementation(() => {});
			const ch = await connectAndPush();
			ch.__firePush("error", { reason: "frame_too_large" });
			expect(sessionMock.scheduleRehandshake).not.toHaveBeenCalled();
			expect(spy).toHaveBeenCalled();
			spy.mockRestore();
		});

		it("error {} (unknown reason) → rehandshake after 1000ms", async () => {
			const ch = await connectAndPush();
			ch.__firePush("error", {});
			expect(sessionMock.scheduleRehandshake).toHaveBeenCalledWith(DOC, 1000);
		});

		it("timeout → rehandshake after 1000ms", async () => {
			const ch = await connectAndPush();
			ch.__firePush("timeout");
			expect(sessionMock.scheduleRehandshake).toHaveBeenCalledWith(DOC, 1000);
		});
	});
});
