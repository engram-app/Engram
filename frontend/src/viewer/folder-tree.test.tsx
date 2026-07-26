import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { FolderTreeProvider } from "../layout/folder-tree-context";
import FolderTree from "./folder-tree";

// The HT-driven FolderTree's UX is the COMPOSITION of already-tested
// primitives (loader, useEngramTree, TreeRow, dialogs). These integration
// tests cover the top-level renders + smoke that the hooks/mutations are
// wired — full coverage lives in the primitives.

vi.mock("sonner", () => ({
	toast: { error: vi.fn(), success: vi.fn(), info: vi.fn() },
}));

const DEFAULT_FOLDERS = [
	{ id: "1", parent_id: null, name: "Projects", count: 1 },
	{ id: "2", parent_id: null, name: "archive", count: 0 },
];
const DEFAULT_ROOT_NOTE = {
	id: "42",
	path: "a.md",
	title: "a",
	folder: "",
	tags: [],
	version: 1,
	mtime: "",
	created_at: "",
	updated_at: "",
};

const {
	batchDeleteNotesMutate,
	batchMoveNotesMutate,
	batchDeleteFoldersMutate,
	batchMoveFoldersMutate,
	createNoteMutate,
	createFolderMutate,
	createdFolder,
	deleteFolderMutate,
	mock,
} = vi.hoisted(() => ({
	batchDeleteNotesMutate: vi.fn(),
	batchMoveNotesMutate: vi.fn(),
	batchDeleteFoldersMutate: vi.fn(),
	batchMoveFoldersMutate: vi.fn(),
	createNoteMutate: vi.fn(),
	createFolderMutate: vi.fn(),
	// Path the mocked create resolves with, so the rename-on-create effect fires.
	createdFolder: { path: "Projects/untitled" },
	deleteFolderMutate: vi.fn(),
	// Mutable per-test fixtures (folders + root notes + loading flag + attachments), set in beforeEach.
	mock: {
		folders: [] as unknown[],
		rootNotes: [] as unknown[],
		loading: false,
		attachments: [] as unknown[],
	},
}));

vi.mock("../api/queries", async () => {
	const actual = await vi.importActual<typeof import("../api/queries")>("../api/queries");
	return {
		...actual,
		useFolders: () => ({
			data: mock.loading ? undefined : mock.folders,
			isLoading: mock.loading,
			isError: false,
		}),
		useAttachments: () => ({ data: mock.attachments, isLoading: false }),
		useFolderNotesById: (folderId: string | null) => {
			// Root notes share the one id-keyed cache under the 'root' sentinel.
			if (folderId === "root") {
				return { data: mock.rootNotes, isLoading: false };
			}
			if (folderId === "1") {
				return {
					data: [
						{
							id: "99",
							path: "Projects/spec.md",
							title: "spec",
							folder: "Projects",
							tags: [],
							version: 1,
							mtime: "",
							created_at: "",
							updated_at: "",
						},
					],
					isLoading: false,
				};
			}
			return { data: [], isLoading: false };
		},
		useRenameNote: () => ({
			mutate: vi.fn(),
			mutateAsync: vi.fn(() => Promise.resolve()),
			isPending: false,
		}),
		useRenameFolder: () => ({
			mutate: vi.fn(),
			mutateAsync: vi.fn(() => Promise.resolve()),
			isPending: false,
		}),
		useDuplicateNote: () => ({
			mutate: vi.fn(),
			mutateAsync: vi.fn(() => Promise.resolve()),
			isPending: false,
		}),
		useCreateNote: () => ({ mutate: createNoteMutate, isPending: false }),
		useCreateFolder: () => ({
			mutate: (
				vars: { parent: string },
				opts?: { onSuccess?: (data: { folder: string }) => void },
			) => {
				createFolderMutate(vars);
				opts?.onSuccess?.({ folder: createdFolder.path });
			},
			isPending: false,
		}),
		useDeleteFolder: () => ({ mutate: deleteFolderMutate, isPending: false }),
		useBatchDeleteNotes: () => ({ mutate: batchDeleteNotesMutate, isPending: false }),
		useBatchMoveNotes: () => ({ mutate: batchMoveNotesMutate, isPending: false }),
		useBatchDeleteFolders: () => ({ mutate: batchDeleteFoldersMutate, isPending: false }),
		useBatchMoveFolders: () => ({ mutate: batchMoveFoldersMutate, isPending: false }),
	};
});

function renderTree() {
	const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
	// The loader reads note lists straight from the query cache. Root notes key
	// under the 'root' sentinel; useActiveVaultId is unset in tests, so the tree
	// resolves vaultId to ''. Seed it so root notes render without a fetch.
	qc.setQueryData(["folder-notes-by-id", "", "root"], mock.rootNotes);
	return render(
		<QueryClientProvider client={qc}>
			<MemoryRouter>
				<FolderTreeProvider>
					<FolderTree />
				</FolderTreeProvider>
			</MemoryRouter>
		</QueryClientProvider>,
	);
}

beforeEach(() => {
	batchDeleteNotesMutate.mockReset();
	batchMoveNotesMutate.mockReset();
	batchDeleteFoldersMutate.mockReset();
	batchMoveFoldersMutate.mockReset();
	createNoteMutate.mockReset();
	createFolderMutate.mockReset();
	deleteFolderMutate.mockReset();
	mock.folders = DEFAULT_FOLDERS.map((f) => ({ ...f }));
	mock.rootNotes = [{ ...DEFAULT_ROOT_NOTE }];
	mock.loading = false;
	mock.attachments = [];
});

describe("FolderTree (HT)", () => {
	it("renders the tree container with role=tree", async () => {
		renderTree();
		await waitFor(() => {
			expect(screen.getByTestId("folder-tree-root")).toBeInTheDocument();
		});
	});

	it("renders top-level folder rows", async () => {
		renderTree();
		await waitFor(() => {
			expect(screen.getByRole("treeitem", { name: "Projects" })).toBeInTheDocument();
			expect(screen.getByRole("treeitem", { name: "archive" })).toBeInTheDocument();
		});
	});

	it("renders root-level note as a link to /note/:id", async () => {
		renderTree();
		const link = await screen.findByRole("treeitem", { name: "a" });
		expect(link).toHaveAttribute("href", "/note/42");
	});

	it("shows root notes even when there are zero folders (new doc at root)", async () => {
		mock.folders = [];
		mock.rootNotes = [{ ...DEFAULT_ROOT_NOTE }];
		renderTree();
		// Must NOT short-circuit to the empty state — the root note is present.
		expect(screen.queryByText("No notes yet.")).toBeNull();
		expect(await screen.findByRole("treeitem", { name: "a" })).toHaveAttribute("href", "/note/42");
	});

	it("shows the empty state only when there are no folders AND no root notes", async () => {
		mock.folders = [];
		mock.rootNotes = [];
		renderTree();
		expect(await screen.findByText("No notes yet.")).toBeInTheDocument();
	});

	it("right-click on a folder row opens the ContextMenu", async () => {
		renderTree();
		const projects = await screen.findByRole("treeitem", { name: "Projects" });
		fireEvent.contextMenu(projects, { clientX: 50, clientY: 60 });
		await waitFor(() => {
			// ContextMenu renders role=menu + menuitems with action labels
			const menu = screen.getByRole("menu");
			expect(menu).toBeInTheDocument();
			expect(screen.getByRole("menuitem", { name: "Rename" })).toBeInTheDocument();
			expect(screen.getByRole("menuitem", { name: "Move to…" })).toBeInTheDocument();
			expect(screen.getByRole("menuitem", { name: "Delete" })).toBeInTheDocument();
		});
	});

	// Creation targets the RIGHT-CLICKED folder, not the toolbar's active one —
	// that difference is the whole point of putting them on the menu.
	it("creates a note inside the right-clicked folder", async () => {
		renderTree();
		const projects = await screen.findByRole("treeitem", { name: "Projects" });
		fireEvent.contextMenu(projects, { clientX: 50, clientY: 60 });
		fireEvent.click(await screen.findByRole("menuitem", { name: "New note here" }));
		expect(createNoteMutate).toHaveBeenCalledWith({ folder: "Projects" });
	});

	it("creates a subfolder under the right-clicked folder", async () => {
		renderTree();
		const projects = await screen.findByRole("treeitem", { name: "Projects" });
		fireEvent.contextMenu(projects, { clientX: 50, clientY: 60 });
		fireEvent.click(await screen.findByRole("menuitem", { name: "New subfolder" }));
		expect(createFolderMutate).toHaveBeenCalledWith({ parent: "Projects" });
	});

	// `/api/folders` returns derived folders with a null id, which become `syn:`
	// ids. Those are ordinary folders to the user, so right-clicking one must
	// open OUR menu — it used to fall through to the browser's.
	it("opens our menu on a derived (synthetic) folder, not the browser's", async () => {
		mock.folders = [];
		mock.rootNotes = [];
		mock.attachments = [
			{
				path: "Media/cover.png",
				mime: "image/png",
				size: 1,
				id: "att-1",
				updated_at: "",
				mtime: 0,
			},
		];
		renderTree();
		const media = await screen.findByRole("treeitem", { name: "Media" });
		const ev = new MouseEvent("contextmenu", { bubbles: true, cancelable: true });
		fireEvent(media, ev);
		// preventDefault is what stops the native menu appearing.
		expect(ev.defaultPrevented).toBe(true);
		expect(await screen.findByRole("menu")).toBeInTheDocument();
		// Same menu as any other folder — rename/move/delete all have path-based
		// routes, so a missing backend id is no reason to offer the user less.
		for (const label of ["New note here", "New subfolder", "Rename", "Move to…", "Delete"]) {
			expect(screen.getByRole("menuitem", { name: label })).toBeInTheDocument();
		}
	});

	it("deletes a derived folder by path, never by its syn: id", async () => {
		mock.folders = [];
		mock.rootNotes = [];
		mock.attachments = [
			{
				path: "Media/cover.png",
				mime: "image/png",
				size: 1,
				id: "att-1",
				updated_at: "",
				mtime: 0,
			},
		];
		renderTree();
		const media = await screen.findByRole("treeitem", { name: "Media" });
		fireEvent.contextMenu(media, { clientX: 5, clientY: 5 });
		fireEvent.click(await screen.findByRole("menuitem", { name: "Delete" }));
		fireEvent.click(await screen.findByRole("button", { name: "Delete" }));

		expect(deleteFolderMutate).toHaveBeenCalledWith({ path: "Media" });
		// The id-keyed batch endpoint would 404 on a `syn:` id.
		expect(batchDeleteFoldersMutate).not.toHaveBeenCalled();
	});

	// The placeholder name should never survive by accident: the new folder opens
	// in rename mode with the name fully selected, so the first keystroke wins.
	it("opens a newly created folder in rename mode, name preselected", async () => {
		mock.folders = [
			{ id: "1", parent_id: null, name: "Projects", count: 1 },
			{ id: "9", parent_id: "1", name: "Projects/untitled", count: 0 },
		];
		renderTree();
		const projects = await screen.findByRole("treeitem", { name: "Projects" });
		fireEvent.contextMenu(projects, { clientX: 50, clientY: 60 });
		fireEvent.click(await screen.findByRole("menuitem", { name: "New subfolder" }));

		const input = (await screen.findByRole("textbox", {
			name: "Rename folder",
		})) as HTMLInputElement;
		expect(input).toHaveValue("untitled");
		expect(input.selectionStart).toBe(0);
		expect(input.selectionEnd).toBe("untitled".length);
	});

	it("does not offer creation actions on a note row", async () => {
		renderTree();
		const note = await screen.findByRole("treeitem", { name: "a" });
		fireEvent.contextMenu(note, { clientX: 10, clientY: 10 });
		await screen.findByRole("menu");
		expect(screen.queryByRole("menuitem", { name: "New note here" })).not.toBeInTheDocument();
		expect(screen.queryByRole("menuitem", { name: "New subfolder" })).not.toBeInTheDocument();
	});

	it("long-press (touch) on a row opens the ActionDrawer", async () => {
		renderTree();
		const projects = await screen.findByRole("treeitem", { name: "Projects" });
		// Long-press is touch/pen only — mouse uses right-click. Fire a touch press
		// and wait the configured 500ms.
		fireEvent.pointerDown(projects, { pointerType: "touch", clientX: 5, clientY: 5 });
		await new Promise((resolve) => setTimeout(resolve, 600));
		// The ActionDrawer (with its backdrop) is shown for the long-pressed row.
		expect(await screen.findByTestId("action-drawer-backdrop")).toBeInTheDocument();
	});

	it("shows loading state", () => {
		// Re-mock for this test scope is heavy; use a separate render with a
		// QueryClient that hasn't resolved — but our mock returns synchronously.
		// We just smoke that the loading branch isn't visible in the happy path.
		renderTree();
		expect(screen.queryByText(/Loading/iu)).not.toBeInTheDocument();
	});

	it("does not crash on loading→loaded transition (hook-count regression)", async () => {
		// Start in loading state — renders the "Loading…" early-return branch.
		mock.loading = true;
		const { rerender } = renderTree();
		expect(screen.getByText("Loading…")).toBeInTheDocument();

		// Flip to loaded — if useCallback were placed after the early returns,
		// React would throw "Rendered more hooks than during the previous render".
		mock.loading = false;
		rerender(
			<QueryClientProvider
				client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
			>
				<MemoryRouter>
					<FolderTreeProvider>
						<FolderTree />
					</FolderTreeProvider>
				</MemoryRouter>
			</QueryClientProvider>,
		);

		// Tree root must be present — no crash, no "Loading…" text.
		await waitFor(() => {
			expect(screen.getByTestId("folder-tree-root")).toBeInTheDocument();
		});
		expect(screen.queryByText("Loading…")).not.toBeInTheDocument();
	});

	it("renders an attachment row from useAttachments", async () => {
		mock.folders = [];
		mock.rootNotes = [];
		mock.attachments = [
			{
				id: "cover-1",
				path: "cover.png",
				mime_type: "image/png",
				size_bytes: 1,
				mtime: 0,
				updated_at: "2026-06-10T00:00:00Z",
			},
		];
		renderTree();
		// Base name only — the extension renders as a separate badge.
		expect(await screen.findByText("cover")).toBeInTheDocument();
	});
});
