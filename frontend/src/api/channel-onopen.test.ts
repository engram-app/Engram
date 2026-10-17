import { afterEach, describe, expect, it, vi } from "vitest";
import { englishT } from "@/i18n/translate";
import { backfillOnWake, connectChannel, disconnectChannel } from "./channel";

// Minimal phoenix mock: capture the onOpen callback and the channel handlers.
// Uses vi.hoisted + a constructor function (not arrow) so `new Socket(...)` works.
const {
	onOpen,
	channelOn: _channelOn,
	join: _join,
	socketCtor,
	channelState,
} = vi.hoisted(() => {
	const onOpen = vi.fn();
	const channelOn = vi.fn();
	const join = vi.fn(() => ({ receive: () => ({ receive: () => {} }) }));
	// phoenix's Channel#state, shared by every channel the mock hands out.
	const channelState = { value: "joined" };
	const socketCtor = vi.fn(function MockSocket(this: object) {
		Object.assign(this, {
			connect: vi.fn(),
			disconnect: vi.fn(),
			onError: vi.fn(),
			onOpen,
			channel: vi.fn(() => ({
				on: channelOn,
				join,
				leave: vi.fn(),
				get state() {
					return channelState.value;
				},
			})),
		});
	});
	return { onOpen, channelOn, join, socketCtor, channelState };
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
	it("stales the vault tree and the dashboard note lists on (re)connect", async () => {
		const invalidateQueries = vi.fn();
		const queryClient = { invalidateQueries } as never;

		await connectChannel({
			userId: "u1",
			vaultId: "v1",
			getToken: async () => "t",
			queryClient,
			t: englishT,
		});

		const registered = onOpen.mock.calls[0]![0] as () => void;
		registered();

		// The whole sidebar — folders, attachments, every folder's notes — is a
		// view of this one key, so staling it is the entire catch-up. The old
		// per-family fan-out (with refetchType "all", because those views had no
		// observers of their own) is gone with the families.
		expect(invalidateQueries).toHaveBeenCalledWith({ queryKey: ["vault-tree", "v1"] });
		expect(invalidateQueries).toHaveBeenCalledWith({ queryKey: ["folderNotes", "v1"] });
		// No `['syncManifest']` line: the `[[` autocomplete inventory is a view of
		// the tree too, so it converges with it.
	});
});

// A wake (focus/visible/online) on a live socket used to re-download the whole
// vault even though the sync channel never left, so it had missed nothing.
// Closing the OS file picker fires `focus`, which is part of why one upload
// cost more than one tree fetch in prod.
describe("backfillOnWake", () => {
	async function connected() {
		const invalidateQueries = vi.fn();
		await connectChannel({
			userId: "u1",
			vaultId: "v1",
			getToken: async () => "t",
			queryClient: { invalidateQueries } as never,
			t: englishT,
		});
		const treeFetches = () =>
			invalidateQueries.mock.calls.filter(([f]) => f.queryKey[0] === "vault-tree").length;
		return { qc: { invalidateQueries } as never, treeFetches };
	}

	it("skips the re-fetch while the sync channel has stayed joined", async () => {
		channelState.value = "joined";
		const { qc, treeFetches } = await connected();
		backfillOnWake(qc, "v1");
		expect(treeFetches()).toBe(0);
	});

	// Errored or still (re)joining: broadcasts in that window were dropped.
	it.each(["errored", "joining", "closed"])("re-fetches when the channel is %s", async (state) => {
		channelState.value = state;
		const { qc, treeFetches } = await connected();
		backfillOnWake(qc, "v1");
		expect(treeFetches()).toBe(1);
	});

	it("re-fetches when there is no channel at all", () => {
		const invalidateQueries = vi.fn();
		backfillOnWake({ invalidateQueries } as never, "v1");
		expect(invalidateQueries).toHaveBeenCalledWith({ queryKey: ["vault-tree", "v1"] });
	});
});
