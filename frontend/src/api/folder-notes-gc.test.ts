import { QueryClient } from "@tanstack/react-query";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { folderNotesByIdQueryOptions } from "./queries";

const { get } = vi.hoisted(() => ({ get: vi.fn() }));
vi.mock("./client", async () => {
	const actual = await vi.importActual<typeof import("./client")>("./client");
	return {
		...actual,
		api: { get, post: vi.fn(), patch: vi.fn(), del: vi.fn() },
		setTokenGetter: vi.fn(),
	};
});

const TREE = {
	folders: [{ id: "f1", name: "Projects", count: 1, parent_id: null }],
	notes: [{ id: "n1", path: "Projects/a.md", created_at: "2026-01-01", updated_at: "2026-01-01" }],
	attachments: [],
};

describe("folder-notes-by-id cache lifetime", () => {
	beforeEach(() => {
		vi.useFakeTimers();
		get.mockResolvedValue(TREE);
	});
	afterEach(() => {
		vi.useRealTimers();
	});

	// The sidebar tree's loader reads this cache with `getQueryData` and fills it
	// with `fetchQuery` — it never mounts an observer for a subfolder. An
	// observerless query is garbage-collected after `gcTime`, and the tree's
	// QueryCache subscription rebuilds on `removed`, so the folder's notes
	// disappear from the sidebar until a fresh /vault/tree round trip lands.
	it("survives longer than the default gcTime with no observers", async () => {
		const qc = new QueryClient({ defaultOptions: { queries: { staleTime: 30_000, retry: 1 } } });
		const opts = folderNotesByIdQueryOptions(qc, "v1", "f1");
		await qc.fetchQuery(opts);
		expect(qc.getQueryData(opts.queryKey)).toHaveLength(1);

		await vi.advanceTimersByTimeAsync(10 * 60_000);

		expect(qc.getQueryData(opts.queryKey)).toHaveLength(1);
	});
});
