import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, renderHook, screen, waitFor } from "@testing-library/react";
import type React from "react";
import { MemoryRouter } from "react-router";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { FolderTreeProvider } from "../layout/folder-tree-context";
import FolderTree from "../viewer/folder-tree";
import { syntheticFolderId } from "../viewer/tree/synthesize-folders";
import { __resetNoteChangeBatch, backfillStructural, handleNoteChanged } from "./channel";
import { type NoteSummary, useAttachments, useFolders, useVaultNotes } from "./queries";
import { dirOf } from "./vault-tree-patch";

// What the sidebar shows for one folder. The tree loader filters the vault's
// notes by folder path, so the tests do the same over the REAL `useVaultNotes`
// view — the per-folder query this used to go through no longer exists.
function useNotesIn(folderPath: string) {
	const q = useVaultNotes();
	return { ...q, data: q.data?.filter((n) => dirOf(n.path) === folderPath) };
}

vi.mock("sonner", () => ({
	toast: { error: vi.fn(), success: vi.fn(), info: vi.fn() },
}));

const { get } = vi.hoisted(() => ({ get: vi.fn() }));
vi.mock("./client", async () => {
	const actual = await vi.importActual<typeof import("./client")>("./client");
	return {
		...actual,
		api: { get, post: vi.fn(), patch: vi.fn(), del: vi.fn() },
		setTokenGetter: vi.fn(),
	};
});

const activeVault = { id: "42" as string | null };
vi.mock("./active-vault", async () => {
	const actual = await vi.importActual<typeof import("./active-vault")>("./active-vault");
	return { ...actual, useActiveVaultId: () => activeVault.id };
});

interface Tree {
	folders: Array<{ id: string | null; name: string; count: number; parent_id: string | null }>;
	notes: Array<{ id: string; path: string; created_at: string; updated_at: string }>;
	attachments: Array<{
		id: string;
		path: string;
		mime_type: string;
		size_bytes: number;
		mtime: number;
		updated_at: string;
	}>;
}

const BASE_TREE: Tree = {
	folders: [
		// The backend echoes a synthetic root row whenever root-level notes exist
		// (`folders_payload/2` groups over existing rows) — selectFolders drops it.
		{ id: null, name: "", count: 1, parent_id: null },
		{ id: "f1", name: "Projects", count: 1, parent_id: null },
		{ id: "f-empty", name: "Empty", count: 0, parent_id: null },
		// A DERIVED folder: no marker row, so the backend sends `id: null` and
		// selectFolders gives it the stable `syn:<path>` id the tree keys on.
		{ id: null, name: "Derived", count: 1, parent_id: null },
	],
	notes: [
		{ id: "n1", path: "Projects/spec.md", created_at: "s", updated_at: "s" },
		{ id: "n2", path: "root.md", created_at: "s", updated_at: "s" },
		{ id: "n3", path: "Derived/a.md", created_at: "s", updated_at: "s" },
	],
	attachments: [
		{
			id: "a1",
			path: "img.png",
			mime_type: "image/png",
			size_bytes: 10,
			mtime: 1_709_234_567,
			updated_at: "2024-06-01T00:00:00Z",
		},
	],
};

// What the server currently holds. Mutate it to simulate a change landing on
// another device, then invalidate the way api/channel.ts does.
let current: Tree = BASE_TREE;

// The pre-redesign per-key endpoints, FROZEN at the first tree. They exist so
// this suite fails loudly (rather than accidentally passing) against a design
// where the sidebar hooks still fetch their own keys: those hooks would happily
// refetch and re-render the pre-change snapshot forever.
function legacyFrozen(url: string): unknown {
	const t = BASE_TREE;
	const notesIn = (folder: string) =>
		t.notes
			.filter(
				(n) => (n.path.includes("/") ? n.path.slice(0, n.path.lastIndexOf("/")) : "") === folder,
			)
			.map((n) => ({ ...n, title: n.path, folder, tags: [], version: 1, mtime: n.updated_at }));
	if (url === "/folders") {
		return { folders: t.folders };
	}
	if (url === "/attachments") {
		return { attachments: t.attachments };
	}
	if (url.startsWith("/folders/by-id/")) {
		const id = url.split("/")[3] ?? "";
		return { notes: notesIn(t.folders.find((f) => f.id === id)?.name ?? "") };
	}
	if (url.startsWith("/folders/list?folder=")) {
		return { notes: notesIn(decodeURIComponent(url.slice("/folders/list?folder=".length))) };
	}
	throw new Error(`unexpected request: ${url}`);
}

function wrapperFor(qc: QueryClient) {
	return function Wrapper({ children }: { children: React.ReactNode }) {
		return <QueryClientProvider client={qc}>{children}</QueryClientProvider>;
	};
}

function newQc() {
	return new QueryClient({ defaultOptions: { queries: { retry: false } } });
}

const urls = () => get.mock.calls.map((c) => c[0] as string);

beforeEach(() => {
	get.mockReset();
	activeVault.id = "42";
	current = BASE_TREE;
	get.mockImplementation((url: string) =>
		url === "/vault/tree" ? Promise.resolve(current) : Promise.resolve(legacyFrozen(url)),
	);
});

describe("the vault tree is the single source for the sidebar views", () => {
	it("cold-loads folders, attachments and root notes from ONE /vault/tree request", async () => {
		const wrapper = wrapperFor(newQc());
		const { result } = renderHook(
			() => ({
				folders: useFolders(),
				attachments: useAttachments(),
				rootNotes: useNotesIn(""),
			}),
			{ wrapper },
		);

		await waitFor(() => {
			expect(result.current.folders.data).toBeDefined();
			expect(result.current.attachments.data).toBeDefined();
			expect(result.current.rootNotes.data).toBeDefined();
		});

		// One request, and specifically NOT /api/folders, /api/attachments or
		// /api/folders/list?folder= — the fan-out this endpoint exists to kill.
		expect(urls()).toEqual(["/vault/tree"]);
	});

	it("useFolders keeps the raw wire shape select expects: root row dropped, id + parent_id intact", async () => {
		const wrapper = wrapperFor(newQc());
		const { result } = renderHook(() => useFolders(), { wrapper });
		await waitFor(() => expect(result.current.data).toBeDefined());

		expect(result.current.data).toEqual([
			{ id: "f1", name: "Projects", count: 1, parent_id: null },
			{ id: "f-empty", name: "Empty", count: 0, parent_id: null },
			{ id: syntheticFolderId("Derived"), name: "Derived", count: 1, parent_id: null },
		]);
	});

	it("useAttachments carries mtime and updated_at through unchanged", async () => {
		const wrapper = wrapperFor(newQc());
		const { result } = renderHook(() => useAttachments(), { wrapper });
		await waitFor(() => expect(result.current.data).toBeDefined());

		// loader.ts sorts by mtime under a "modified-*" sort and
		// use-engram-tree.ts fingerprints updated_at to decide whether to rebuild
		// — a placeholder for either silently breaks ordering / live rebuilds.
		expect(result.current.data).toEqual([
			{
				id: "a1",
				path: "img.png",
				mime_type: "image/png",
				size_bytes: 10,
				mtime: 1_709_234_567,
				updated_at: "2024-06-01T00:00:00Z",
			},
		]);
	});

	it("buckets notes by folder: a marker folder, the root, and a folder with no marker", async () => {
		const wrapper = wrapperFor(newQc());
		const { result } = renderHook(
			() => ({
				projects: useNotesIn("Projects"),
				root: useNotesIn(""),
				derived: useNotesIn("Derived"),
			}),
			{ wrapper },
		);

		await waitFor(() => {
			expect(result.current.projects.data).toBeDefined();
			expect(result.current.root.data).toBeDefined();
			expect(result.current.derived.data).toBeDefined();
		});

		expect(result.current.projects.data?.map((n: NoteSummary) => n.id)).toEqual(["n1"]);
		expect(result.current.root.data?.map((n: NoteSummary) => n.id)).toEqual(["n2"]);
		expect(result.current.derived.data?.map((n: NoteSummary) => n.id)).toEqual(["n3"]);
		expect(urls()).toEqual(["/vault/tree"]);
	});

	it("an empty folder is answered from the same one request", async () => {
		const qc = newQc();
		const wrapper = wrapperFor(qc);
		const { result } = renderHook(() => useFolders(), { wrapper });
		await waitFor(() => expect(result.current.data).toBeDefined());
		expect(urls()).toEqual(["/vault/tree"]);

		// What the tree loader does on expand: read that folder's notes.
		const empty = renderHook(() => useNotesIn("Empty"), { wrapper });
		await waitFor(() => expect(empty.result.current.data).toBeDefined());

		// `[]` is an ANSWER derived from the already-fetched tree, not a miss that
		// falls through to a per-folder request.
		expect(empty.result.current.data).toEqual([]);
		expect(urls()).toEqual(["/vault/tree"]);
	});

	it("does not fetch at all without an active vault id", async () => {
		activeVault.id = null;
		const wrapper = wrapperFor(newQc());
		const { result } = renderHook(() => ({ folders: useFolders(), att: useAttachments() }), {
			wrapper,
		});
		await waitFor(() => expect(result.current.folders.fetchStatus).toBe("idle"));
		expect(get).not.toHaveBeenCalled();
	});

	// Finding 2. On the FIRST-EVER tree fetch `state.data === undefined`, so
	// query-core COALESCES a mid-flight invalidation onto the running request
	// rather than restarting it, and the success dispatch then clears
	// `isInvalidated` — so a snapshot that predates the event lands marked fresh
	// and nothing asks again. `change_seq` can't detect this (no sync-channel
	// event carries a seq to compare it against), so the invalidation itself is
	// what gets detected.
	it("does not lose a channel invalidation that lands while the FIRST tree fetch is in flight", async () => {
		const qc = newQc();
		let treeCalls = 0;
		let releaseFirst: (t: Tree) => void = () => {};
		const firstResponse = new Promise<Tree>((resolve) => {
			releaseFirst = resolve;
		});
		get.mockImplementation((url: string) => {
			if (url !== "/vault/tree") {
				return Promise.resolve(legacyFrozen(url));
			}
			treeCalls++;
			// Hold the cold-load request open so the invalidation lands mid-flight.
			return treeCalls === 1 ? firstResponse : Promise.resolve(current);
		});

		const { result } = renderHook(() => useNotesIn("Projects"), { wrapper: wrapperFor(qc) });
		await waitFor(() => expect(treeCalls).toBe(1));
		expect(result.current.data).toBeUndefined();

		// Another device moves n1 out of Projects to the vault root. The channel
		// tells us — but the in-flight request was issued BEFORE that write, so
		// its response cannot contain the move.
		current = {
			...BASE_TREE,
			folders: [
				{ id: null, name: "", count: 2, parent_id: null },
				{ id: "f1", name: "Projects", count: 0, parent_id: null },
				{ id: "f-empty", name: "Empty", count: 0, parent_id: null },
				{ id: null, name: "Derived", count: 1, parent_id: null },
			],
			notes: [
				{ id: "n1", path: "spec.md", created_at: "s", updated_at: "s2" },
				{ id: "n2", path: "root.md", created_at: "s", updated_at: "s" },
				{ id: "n3", path: "Derived/a.md", created_at: "s", updated_at: "s" },
			],
		};
		// A real channel entry point (socket reconnect), not a hand-rolled
		// invalidation — it routes through invalidateVaultTree like flushBatch does.
		backfillStructural(qc, "42");

		// ...and only NOW does the pre-event snapshot arrive.
		releaseFirst(BASE_TREE);

		// The note must not still be listed under the folder it left.
		await waitFor(() => expect(result.current.data?.map((n: NoteSummary) => n.id)).toEqual([]));
		// Exactly one extra fetch, not a refetch loop.
		expect(treeCalls).toBe(2);
	});

	// A cancelled tree fetch (an optimistic mutation's snapshot, a restart on
	// invalidation) used to run its whole-vault server-side decrypt to
	// completion for nobody, then maybe retry on top.
	it("aborts the in-flight tree request when the query is cancelled", async () => {
		const qc = newQc();
		let signal: AbortSignal | undefined;
		get.mockImplementation((url: string, opts?: { signal?: AbortSignal }) => {
			if (url !== "/vault/tree") {
				return Promise.resolve(legacyFrozen(url));
			}
			signal = opts?.signal;
			return new Promise<Tree>(() => {});
		});
		renderHook(() => useNotesIn("Projects"), { wrapper: wrapperFor(qc) });
		await waitFor(() => expect(signal).toBeDefined());

		await qc.cancelQueries({ queryKey: ["vault-tree", "42"] });

		expect(signal?.aborted).toBe(true);
	});

	// The invariant CI caught: a cross-tab move must converge in the sidebar
	// with no reload. Invalidate exactly as api/channel.ts's flushBatch does.
	it("converges every derived list when the tree is invalidated the way channel.ts does", async () => {
		const qc = newQc();
		const wrapper = wrapperFor(qc);
		const { result } = renderHook(
			() => ({
				folders: useFolders(),
				projects: useNotesIn("Projects"),
				root: useNotesIn(""),
			}),
			{ wrapper },
		);
		await waitFor(() => expect(result.current.projects.data).toBeDefined());
		expect(result.current.projects.data?.map((n: NoteSummary) => n.id)).toEqual(["n1"]);

		// Another device moves n1 out of Projects to the vault root and adds a
		// folder. The legacy per-key endpoints stay frozen at the OLD state.
		current = {
			...BASE_TREE,
			folders: [
				{ id: null, name: "", count: 2, parent_id: null },
				{ id: "f1", name: "Projects", count: 0, parent_id: null },
				{ id: "f-empty", name: "Empty", count: 0, parent_id: null },
				{ id: null, name: "Derived", count: 1, parent_id: null },
				{ id: "f2", name: "Later", count: 0, parent_id: null },
			],
			notes: [
				{ id: "n1", path: "spec.md", created_at: "s", updated_at: "s2" },
				{ id: "n2", path: "root.md", created_at: "s", updated_at: "s" },
				{ id: "n3", path: "Derived/a.md", created_at: "s", updated_at: "s" },
			],
		};

		// One key. Every view above follows it.
		await qc.invalidateQueries({ queryKey: ["vault-tree", "42"] });

		await waitFor(() => {
			// Gone from its old folder...
			expect(result.current.projects.data?.map((n: NoteSummary) => n.id)).toEqual([]);
			// ...and present in the new one. Listed under BOTH is the CI failure
			// this redesign exists to prevent.
			expect(result.current.root.data?.map((n: NoteSummary) => n.id).sort()).toEqual(["n1", "n2"]);
			expect(result.current.folders.data?.map((f) => f.name)).toContain("Later");
		});
	});
});

// The wiring test that used to be missing: folder-tree.test.tsx stubs every
// query hook, so nothing ever proved FolderTree renders what the tree endpoint
// actually returns. Drive the REAL hooks off a real payload.
describe("FolderTree renders from a real /vault/tree payload", () => {
	it("renders folder, note and attachment rows, from one request", async () => {
		const qc = newQc();
		render(
			<QueryClientProvider client={qc}>
				<MemoryRouter>
					<FolderTreeProvider>
						<FolderTree />
					</FolderTreeProvider>
				</MemoryRouter>
			</QueryClientProvider>,
		);

		expect(await screen.findByRole("treeitem", { name: "Projects" })).toBeInTheDocument();
		expect(await screen.findByRole("treeitem", { name: "Empty" })).toBeInTheDocument();
		// A folder with no marker row still renders, via its syn:<path> id.
		expect(await screen.findByRole("treeitem", { name: "Derived" })).toBeInTheDocument();
		// Root-level note, keyed under the ROOT_FOLDER_ID sentinel.
		expect(await screen.findByRole("treeitem", { name: "root" })).toBeInTheDocument();
		// Attachment rows render the base name; the extension is a separate badge.
		expect(await screen.findByText("img")).toBeInTheDocument();

		// `/vaults` is the row href's slug lookup (api/vault-slug.ts), unrelated to
		// the sidebar's data. Everything the tree renders came from ONE request.
		expect(urls().filter((u) => u !== "/vaults")).toEqual(["/vault/tree"]);
	});
});

// A large first sync streams note events continuously. Each batch that landed
// while a tree fetch was in flight used to invalidate, which re-ran the fetch,
// during which the next batch landed: back-to-back whole-vault fetches for the
// whole sync (prod: 161 in 20 min, ~0.55 CPU-s each). Events seen mid-flight
// are now buffered and replayed onto the response instead.
describe("sync events during an in-flight tree fetch", () => {
	afterEach(() => {
		__resetNoteChangeBatch();
	});

	// Load the tree, then hold its NEXT fetch open until `release` is called.
	async function loadThenHoldRefetch() {
		const qc = newQc();
		let treeCalls = 0;
		let release: (t: Tree) => void = () => {};
		let fail: (e: Error) => void = () => {};
		get.mockImplementation((url: string) => {
			if (url !== "/vault/tree") {
				return Promise.resolve(legacyFrozen(url));
			}
			treeCalls++;
			if (treeCalls === 2) {
				return new Promise<Tree>((resolve, reject) => {
					release = resolve;
					fail = reject;
				});
			}
			return Promise.resolve(current);
		});
		const { result } = renderHook(() => useVaultNotes(), { wrapper: wrapperFor(qc) });
		await waitFor(() => expect(result.current.data).toBeDefined());
		backfillStructural(qc, "42");
		await waitFor(() => expect(treeCalls).toBe(2));
		return {
			qc,
			result,
			calls: () => treeCalls,
			release: (t: Tree) => release(t),
			fail: (e: Error) => fail(e),
		};
	}

	const upsert = (id: string, path: string, updated_at: string) => ({
		event_type: "upsert" as const,
		id,
		path,
		updated_at,
		vault_id: "42",
	});
	// Past the channel's 250 ms coalescing window.
	const flushBatch = () => new Promise((r) => setTimeout(r, 300));

	it("does not re-fetch, and applies the events once the fetch lands", async () => {
		const h = await loadThenHoldRefetch();
		handleNoteChanged(upsert("n9", "Projects/new.md", "u9"), h.qc, "42");
		await flushBatch();
		handleNoteChanged(upsert("n2", "root.md", "u2"), h.qc, "42");
		await flushBatch();

		// The held response was snapshotted before either write.
		h.release(BASE_TREE);

		await waitFor(() =>
			expect(h.result.current.data?.find((n) => n.id === "n9")?.path).toBe("Projects/new.md"),
		);
		expect(h.result.current.data?.find((n) => n.id === "n2")?.updated_at).toBe("u2");
		expect(h.calls()).toBe(2);
	});

	it("does not duplicate a buffered event the response already contains", async () => {
		const h = await loadThenHoldRefetch();
		handleNoteChanged(upsert("n9", "Projects/new.md", "u9"), h.qc, "42");
		await flushBatch();

		const n9 = { id: "n9", path: "Projects/new.md", created_at: "u9", updated_at: "u9" };
		h.release({ ...BASE_TREE, notes: [...BASE_TREE.notes, n9] });

		await waitFor(() => expect(h.result.current.data?.some((n) => n.id === "n9")).toBe(true));
		expect(h.result.current.data?.filter((n) => n.id === "n9")).toHaveLength(1);
		expect(h.calls()).toBe(2);
	});

	// The events live with the request that failed. Replaying them onto a LATER
	// response, issued after they happened, could resurrect a stale state.
	it("drops the buffer when the fetch fails", async () => {
		const h = await loadThenHoldRefetch();
		handleNoteChanged(upsert("n2", "root.md", "stale"), h.qc, "42");
		await flushBatch();
		h.fail(new Error("boom"));
		await waitFor(() => expect(h.qc.getQueryState(["vault-tree", "42"])?.status).toBe("error"));

		// Server truth since then: n2 is gone.
		current = { ...BASE_TREE, notes: BASE_TREE.notes.filter((n) => n.id !== "n2") };
		backfillStructural(h.qc, "42");

		await waitFor(() => expect(h.calls()).toBe(3));
		await waitFor(() => expect(h.result.current.data?.some((n) => n.id === "n2")).toBe(false));
	});

	it("keeps another vault's events out of this vault's buffer", async () => {
		const h = await loadThenHoldRefetch();
		handleNoteChanged({ ...upsert("x1", "other.md", "u"), vault_id: "43" }, h.qc, "43");
		await flushBatch();
		h.release(BASE_TREE);

		await waitFor(() => expect(h.qc.getQueryState(["vault-tree", "42"])?.fetchStatus).toBe("idle"));
		expect(h.result.current.data?.some((n) => n.id === "x1")).toBe(false);
	});

	// A move between folders may be a folder rename; the events say nothing
	// about the marker, so a request issued after the move is still required.
	it("re-fetches once when a buffered event moves a note across folders", async () => {
		const h = await loadThenHoldRefetch();
		handleNoteChanged(upsert("n1", "spec.md", "u2"), h.qc, "42");
		await flushBatch();
		const moved = {
			...BASE_TREE,
			notes: BASE_TREE.notes.map((n) => (n.id === "n1" ? { ...n, path: "spec.md" } : n)),
		};
		current = moved;
		h.release(BASE_TREE);

		await waitFor(() =>
			expect(h.result.current.data?.find((n) => n.id === "n1")?.path).toBe("spec.md"),
		);
		expect(h.calls()).toBe(3);
	});
});
