import { QueryClient } from "@tanstack/react-query";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { beacon, tracingEnabled } from "../observability/trace";
import {
	__resetNoteChangeBatch,
	backfillStructural,
	handleFoldersBatch,
	handleNoteChanged,
	handleNotesBatch,
} from "./channel";
import type { VaultTree } from "./queries";

// Stub the tracing gate + beacon buffer; keep the real parseTraceparent so
// the render beacon's id extraction is exercised end to end. The buffer's
// own transport/flush is covered by observability/trace.test.ts.
vi.mock("../observability/trace", async (importActual) => {
	const actual = await importActual<typeof import("../observability/trace")>();
	return {
		...actual,
		tracingEnabled: vi.fn(() => false),
		beacon: { enqueue: vi.fn(), flush: vi.fn() },
	};
});

function mockQueryClient(foldersData?: unknown) {
	return {
		invalidateQueries: vi.fn(),
		getQueryData: vi.fn(() => foldersData),
		// No tree cached: every flush takes the re-fetch fallback, which is what
		// these invalidation-shape tests assert. The patch path is tested below
		// against a real QueryClient.
		getQueryState: vi.fn(() => undefined),
	} as unknown as QueryClient & {
		invalidateQueries: ReturnType<typeof vi.fn>;
		getQueryData: ReturnType<typeof vi.fn>;
	};
}

beforeEach(() => {
	vi.useFakeTimers();
});

afterEach(() => {
	__resetNoteChangeBatch();
	vi.useRealTimers();
});

describe("handleNoteChanged", () => {
	it("invalidates the per-note query for the upserted path immediately", () => {
		const qc = mockQueryClient();
		handleNoteChanged({ event_type: "upsert", path: "foo/bar.md", vault_id: "7" }, qc, "7");
		expect(qc.invalidateQueries).toHaveBeenCalledWith({ queryKey: ["note", "7", "foo/bar.md"] });
	});

	// A note's edges (forward links AND anyone's backlinks TO it) can change on
	// any content edit, so backlinks panels for OTHER notes go stale the same
	// way folder/search lists do -- invalidate the whole ["backlinks"] family
	// rather than trying to compute which note ids are affected.
	it("invalidates the backlinks query family immediately alongside the note", () => {
		const qc = mockQueryClient();
		handleNoteChanged({ event_type: "upsert", path: "foo/bar.md", vault_id: "7" }, qc, "7");
		expect(qc.invalidateQueries).toHaveBeenCalledWith({ queryKey: ["backlinks"] });
	});

	it("defers list invalidation to a coalescing window, then targets the changed folder", () => {
		const qc = mockQueryClient();
		handleNoteChanged(
			{ event_type: "upsert", path: "docs/a.md", folder: "docs", vault_id: "7" },
			qc,
			"7",
		);

		// List-level keys must NOT fire synchronously.
		const syncKeys = qc.invalidateQueries.mock.calls.map((c) => c[0].queryKey);
		expect(syncKeys).not.toContainEqual(["vault-tree", "7"]);
		expect(syncKeys.some((k) => k[0] === "search")).toBe(false);

		vi.advanceTimersByTime(250);

		const keys = qc.invalidateQueries.mock.calls.map((c) => c[0].queryKey);
		expect(keys).toContainEqual(["vault-tree", "7"]);
		expect(keys).toContainEqual(["folderNotes", "7", "docs"]);
		expect(keys).toContainEqual(["search", "7"]);
		// Untargeted folderNotes (whole-prefix) must not be used when the
		// folder is known.
		expect(keys).not.toContainEqual(["folderNotes", "7"]);
	});

	// The `[[` autocomplete inventory used to be its own `['syncManifest']`
	// query fetched from `/sync/manifest`, needing its own invalidation here or
	// a new note stayed invisible to autocomplete. It is a view of the tree
	// now, so staling the tree IS staling it — and there is no second key left
	// to forget.
	it("needs no separate invalidation for the wikilink inventory", () => {
		const qc = mockQueryClient();
		handleNoteChanged(
			{ event_type: "upsert", path: "docs/a.md", folder: "docs", vault_id: "7" },
			qc,
			"7",
		);
		vi.advanceTimersByTime(250);

		const keys = qc.invalidateQueries.mock.calls.map((c) => c[0].queryKey);
		expect(keys).toContainEqual(["vault-tree", "7"]);
		expect(keys).not.toContainEqual(["syncManifest", "7"]);
	});

	it("coalesces a sync burst into one flush per distinct folder", () => {
		const qc = mockQueryClient();
		for (let i = 0; i < 50; i++) {
			handleNoteChanged(
				{ event_type: "upsert", path: `a/n${i}.md`, folder: "a", vault_id: "7" },
				qc,
				"7",
			);
			handleNoteChanged(
				{ event_type: "upsert", path: `b/n${i}.md`, folder: "b", vault_id: "7" },
				qc,
				"7",
			);
		}

		vi.advanceTimersByTime(250);

		const calls = qc.invalidateQueries.mock.calls.map((c) => c[0].queryKey);
		const folderNotesCalls = calls.filter((k) => k[0] === "folderNotes");
		const treeCalls = calls.filter((k) => k[0] === "vault-tree");
		const searchCalls = calls.filter((k) => k[0] === "search");

		expect(folderNotesCalls).toEqual(
			expect.arrayContaining([
				["folderNotes", "7", "a"],
				["folderNotes", "7", "b"],
			]),
		);
		expect(folderNotesCalls).toHaveLength(2);
		expect(treeCalls).toHaveLength(1);
		expect(searchCalls).toHaveLength(1);
	});

	// A note event used to fan out to a per-folder key, which meant resolving
	// the folder's marker id first — and getting that wrong (a DERIVED folder's
	// raw id is null) silently invalidated a key nothing reads. There is one key
	// now, so there is nothing to resolve and nothing to get wrong.
	it("stales the vault tree once, whatever folder the note is in", () => {
		const qc = mockQueryClient({ folders: [] });

		handleNoteChanged(
			{ event_type: "upsert", path: "brand-new/a.md", folder: "brand-new", vault_id: "7" },
			qc,
			"7",
		);
		vi.advanceTimersByTime(250);

		const keys = qc.invalidateQueries.mock.calls.map((c) => c[0].queryKey);
		expect(keys.filter((k) => k[0] === "vault-tree")).toHaveLength(1);
	});

	it("derives the folder from the path when the payload omits it (delete events)", () => {
		const qc = mockQueryClient();
		handleNoteChanged({ event_type: "delete", path: "docs/gone.md", vault_id: "7" }, qc, "7");

		expect(qc.invalidateQueries).toHaveBeenCalledWith({ queryKey: ["note", "7", "docs/gone.md"] });

		vi.advanceTimersByTime(250);
		const keys = qc.invalidateQueries.mock.calls.map((c) => c[0].queryKey);
		expect(keys).toContainEqual(["folderNotes", "7", "docs"]);
	});

	it("ignores payloads from a different vault (avoids cross-vault noise)", () => {
		const qc = mockQueryClient();
		handleNoteChanged({ event_type: "upsert", path: "a.md", vault_id: "99" }, qc, "7");
		vi.advanceTimersByTime(250);
		expect(qc.invalidateQueries).not.toHaveBeenCalled();
	});

	it("regression: the bug from #277 — payload has no `kind` field; handler must still fire", () => {
		const qc = mockQueryClient();
		// Server actually sends `event_type`, never `kind`. The old handler gated on
		// `payload.kind === 'note'` and silently dropped every event.
		handleNoteChanged(
			{ event_type: "upsert", path: "x.md", vault_id: "7", content: "hello" },
			qc,
			"7",
		);
		expect(qc.invalidateQueries).toHaveBeenCalled();
	});
});

describe("handleNoteChanged render beacon (leg B)", () => {
	const TP = `00-${"a".repeat(32)}-${"b".repeat(16)}-01`;

	beforeEach(() => {
		vi.mocked(tracingEnabled).mockReturnValue(false);
		vi.mocked(beacon.enqueue).mockClear();
	});

	it("enqueues a render beacon parented to the payload traceparent when tracing on", () => {
		vi.mocked(tracingEnabled).mockReturnValue(true);
		const qc = mockQueryClient();
		handleNoteChanged(
			{ event_type: "upsert", path: "n.md", vault_id: "7", traceparent: TP },
			qc,
			"7",
		);

		expect(beacon.enqueue).toHaveBeenCalledTimes(1);
		const entry = vi.mocked(beacon.enqueue).mock.lastCall?.[0];
		if (!entry) {
			throw new Error("expected a render beacon to be enqueued");
		}
		expect(entry.name).toBe("browser.live_sync.render");
		expect(entry.trace_id).toBe("a".repeat(32));
		expect(entry.parent_span_id).toBe("b".repeat(16));
		expect(entry.attributes["engram.surface"]).toBe("web");
		expect(entry.attributes["engram.event_type"]).toBe("upsert");
	});

	it("enqueues nothing when tracing is disabled (zero-cost guarantee)", () => {
		const qc = mockQueryClient();
		handleNoteChanged(
			{ event_type: "upsert", path: "n.md", vault_id: "7", traceparent: TP },
			qc,
			"7",
		);
		expect(beacon.enqueue).not.toHaveBeenCalled();
	});

	it("enqueues nothing when the payload carries no traceparent", () => {
		vi.mocked(tracingEnabled).mockReturnValue(true);
		const qc = mockQueryClient();
		handleNoteChanged({ event_type: "upsert", path: "n.md", vault_id: "7" }, qc, "7");
		expect(beacon.enqueue).not.toHaveBeenCalled();
	});

	it("does not beacon a change dropped by the cross-vault guard", () => {
		vi.mocked(tracingEnabled).mockReturnValue(true);
		const qc = mockQueryClient();
		handleNoteChanged(
			{ event_type: "upsert", path: "n.md", vault_id: "9", traceparent: TP },
			qc,
			"7",
		);
		expect(beacon.enqueue).not.toHaveBeenCalled();
	});
});

describe("handleNotesBatch", () => {
	it("applies per-note invalidations for an upsert digest (bulk push)", () => {
		const qc = mockQueryClient();
		handleNotesBatch(
			{
				op: "upsert",
				vault_id: "7",
				notes: [
					{ id: "id-1", path: "docs/a.md", folder: "docs", content_hash: "h1" },
					{ id: "id-2", path: "notes/b.md", folder: "notes", content_hash: "h2" },
				],
			},
			qc,
			"7",
		);

		const syncKeys = qc.invalidateQueries.mock.calls.map((c) => c[0].queryKey);
		expect(syncKeys).toContainEqual(["note", "7", "id-1"]);
		expect(syncKeys).toContainEqual(["note", "7", "docs/a.md"]);
		expect(syncKeys).toContainEqual(["note", "7", "id-2"]);

		vi.advanceTimersByTime(250);

		const keys = qc.invalidateQueries.mock.calls.map((c) => c[0].queryKey);
		expect(keys).toContainEqual(["vault-tree", "7"]);
		expect(keys).toContainEqual(["folderNotes", "7", "docs"]);
		expect(keys).toContainEqual(["folderNotes", "7", "notes"]);
	});

	it("ignores digests from a different vault", () => {
		const qc = mockQueryClient();
		handleNotesBatch(
			{ op: "upsert", vault_id: "other", notes: [{ id: "x", path: "a.md" }] },
			qc,
			"7",
		);
		expect(qc.invalidateQueries).not.toHaveBeenCalled();
	});

	it("ignores non-upsert ops", () => {
		const qc = mockQueryClient();
		handleNotesBatch({ op: "delete", vault_id: "7" }, qc, "7");
		expect(qc.invalidateQueries).not.toHaveBeenCalled();
	});
});

describe("handleFoldersBatch", () => {
	it("refetches the folder tree so a folder delete lands live", () => {
		const qc = mockQueryClient();
		handleFoldersBatch({ op: "delete", folder: "Gone" }, qc, "7");
		expect(qc.invalidateQueries).toHaveBeenCalledWith({ queryKey: ["vault-tree", "7"] });
	});

	it("refetches the folder tree so a folder create lands live", () => {
		const qc = mockQueryClient();
		handleFoldersBatch({ op: "create", folder: "New/Empty" }, qc, "7");
		expect(qc.invalidateQueries).toHaveBeenCalledWith({ queryKey: ["vault-tree", "7"] });
	});
});

describe("backfillStructural", () => {
	// A backgrounded/offline tab misses note events with no replay, so the
	// reconnect backfill has to stale everything structural. That is one key.
	it("stales the vault tree, which is every structural view", () => {
		const qc = mockQueryClient();
		backfillStructural(qc, "7");
		const keys = qc.invalidateQueries.mock.calls.map((c) => c[0].queryKey);
		expect(keys).toContainEqual(["vault-tree", "7"]);
	});
});

// The sync channel patches the one vault-tree entry instead of re-downloading
// the whole vault per event burst. These run against a REAL QueryClient,
// because what matters is what ends up in the cache and whether a refetch was
// asked for.
describe("note events patch the vault tree in place", () => {
	const TREE: VaultTree = {
		folders: [{ id: "m-docs", name: "docs", count: 1, parent_id: null }],
		notes: [{ id: "n1", path: "docs/a.md", created_at: "c", updated_at: "u1" }],
		attachments: [],
	};

	function setup() {
		const qc = new QueryClient();
		qc.setQueryData(["vault-tree", "7"], TREE);
		const invalidate = vi.spyOn(qc, "invalidateQueries");
		const treeRefetches = () =>
			invalidate.mock.calls.filter(([f]) => f?.queryKey?.[0] === "vault-tree").length;
		const tree = () => qc.getQueryData<VaultTree>(["vault-tree", "7"]);
		return { qc, invalidate, treeRefetches, tree };
	}

	const flush = () => vi.advanceTimersByTime(250);

	it("applies a note edit without re-downloading the vault", () => {
		const { qc, treeRefetches, tree } = setup();
		handleNoteChanged(
			{ event_type: "upsert", id: "n1", path: "docs/a.md", updated_at: "u2", vault_id: "7" },
			qc,
			"7",
		);
		flush();
		expect(treeRefetches()).toBe(0);
		expect(tree()?.notes[0]?.updated_at).toBe("u2");
	});

	it("converges a rename (delete + upsert, one id) to a single row at the new path", () => {
		const { qc, treeRefetches, tree } = setup();
		const ev = { vault_id: "7", id: "n1" };
		handleNoteChanged(
			{ ...ev, event_type: "upsert", path: "docs/b.md", updated_at: "u2" },
			qc,
			"7",
		);
		handleNoteChanged({ ...ev, event_type: "delete", path: "docs/a.md" }, qc, "7");
		flush();
		expect(treeRefetches()).toBe(0);
		expect(tree()?.notes.map((n) => n.path)).toEqual(["docs/b.md"]);
	});

	// A folder rename is broadcast as per-note upsert+delete pairs and NOTHING
	// about the folder marker, so patching would keep the old folder listed.
	// Caught by e2e "rename folder propagates to a second tab".
	it("re-fetches when a note moves to a different folder", () => {
		const { qc, treeRefetches } = setup();
		const ev = { vault_id: "7", id: "n1" };
		handleNoteChanged(
			{ ...ev, event_type: "upsert", path: "renamed/a.md", updated_at: "u2" },
			qc,
			"7",
		);
		handleNoteChanged({ ...ev, event_type: "delete", path: "docs/a.md" }, qc, "7");
		flush();
		expect(treeRefetches()).toBe(1);
	});

	it("stales the index cap when a note appears or disappears", () => {
		const { qc, invalidate } = setup();
		handleNoteChanged(
			{ event_type: "upsert", id: "n2", path: "docs/new.md", updated_at: "u", vault_id: "7" },
			qc,
			"7",
		);
		flush();
		expect(invalidate).toHaveBeenCalledWith({ queryKey: ["index_status"] });
	});

	it("falls back to a re-fetch for an attachment event", () => {
		const { qc, treeRefetches } = setup();
		handleNoteChanged(
			{ event_type: "upsert", kind: "attachment", path: "docs/pic.png", vault_id: "7" },
			qc,
			"7",
		);
		flush();
		expect(treeRefetches()).toBe(1);
	});

	// A fetch that started before these events would land its (older) response
	// on top of the patch and silently undo it. Re-fetching is the only safe
	// move; the invalidation generation makes the in-flight fetch run again.
	it("falls back to a re-fetch while a tree fetch is in flight", () => {
		const { qc, treeRefetches } = setup();
		// Never resolves: the fetch stays in flight for the rest of the test.
		qc.prefetchQuery({
			queryKey: ["vault-tree", "7"],
			queryFn: () => new Promise<VaultTree>(() => {}),
			staleTime: 0,
		});
		handleNoteChanged(
			{ event_type: "upsert", id: "n1", path: "docs/a.md", updated_at: "u2", vault_id: "7" },
			qc,
			"7",
		);
		flush();
		expect(treeRefetches()).toBe(1);
	});
});
