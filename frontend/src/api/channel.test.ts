import type { QueryClient } from "@tanstack/react-query";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { beacon, tracingEnabled } from "../observability/trace";
import { __resetNoteChangeBatch, handleNoteChanged, handleNotesBatch } from "./channel";

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

	it("defers list invalidation to a coalescing window, then targets the changed folder", () => {
		const qc = mockQueryClient();
		handleNoteChanged(
			{ event_type: "upsert", path: "docs/a.md", folder: "docs", vault_id: "7" },
			qc,
			"7",
		);

		// List-level keys must NOT fire synchronously.
		const syncKeys = qc.invalidateQueries.mock.calls.map((c) => c[0].queryKey);
		expect(syncKeys).not.toContainEqual(["folders", "7"]);
		expect(syncKeys.some((k) => k[0] === "search")).toBe(false);

		vi.advanceTimersByTime(250);

		const keys = qc.invalidateQueries.mock.calls.map((c) => c[0].queryKey);
		expect(keys).toContainEqual(["folders", "7"]);
		expect(keys).toContainEqual(["folderNotes", "7", "docs"]);
		expect(keys).toContainEqual(["search", "7"]);
		// Untargeted folderNotes (whole-prefix) must not be used when the
		// folder is known.
		expect(keys).not.toContainEqual(["folderNotes", "7"]);
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
		const foldersCalls = calls.filter((k) => k[0] === "folders");
		const searchCalls = calls.filter((k) => k[0] === "search");

		expect(folderNotesCalls).toEqual(
			expect.arrayContaining([
				["folderNotes", "7", "a"],
				["folderNotes", "7", "b"],
			]),
		);
		expect(folderNotesCalls).toHaveLength(2);
		expect(foldersCalls).toHaveLength(1);
		expect(searchCalls).toHaveLength(1);
	});

	it("resolves folder-notes-by-id keys from the cached folder tree", () => {
		const qc = mockQueryClient({
			folders: [
				{ id: "f1", parent_id: null, name: "docs", count: 3 },
				{ id: "f2", parent_id: null, name: "other", count: 1 },
			],
		});

		handleNoteChanged(
			{ event_type: "upsert", path: "docs/a.md", folder: "docs", vault_id: "7" },
			qc,
			"7",
		);
		vi.advanceTimersByTime(250);

		const keys = qc.invalidateQueries.mock.calls.map((c) => c[0].queryKey);
		expect(keys).toContainEqual(["folder-notes-by-id", "7", "f1"]);
		expect(keys).not.toContainEqual(["folder-notes-by-id", "7", "f2"]);
	});

	it("targets the by-id root sentinel for a root note (no folder marker)", () => {
		const qc = mockQueryClient({ folders: [] });

		// Root note: no folder in the payload, derived as '' from the path.
		handleNoteChanged({ event_type: "upsert", path: "top.md", vault_id: "7" }, qc, "7");
		vi.advanceTimersByTime(250);

		const keys = qc.invalidateQueries.mock.calls.map((c) => c[0].queryKey);
		expect(keys).toContainEqual(["folderNotes", "7", ""]);
		expect(keys).toContainEqual(["folder-notes-by-id", "7", "root"]);
		// Root must NOT fall back to the broad whole-prefix invalidation.
		expect(keys).not.toContainEqual(["folder-notes-by-id", "7"]);
	});

	it("falls back to broad folder-notes-by-id invalidation when the folder is not in cache", () => {
		const qc = mockQueryClient({ folders: [] });

		handleNoteChanged(
			{ event_type: "upsert", path: "brand-new/a.md", folder: "brand-new", vault_id: "7" },
			qc,
			"7",
		);
		vi.advanceTimersByTime(250);

		const keys = qc.invalidateQueries.mock.calls.map((c) => c[0].queryKey);
		expect(keys).toContainEqual(["folder-notes-by-id", "7"]);
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
		expect(keys).toContainEqual(["folders", "7"]);
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
