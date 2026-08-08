import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router";
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

// The tree loader loads a folder's note list from the vault tree on a cache
// miss. Nothing here seeds that tree, so without this the miss path reaches the
// real network; the loader swallows the failure, but the attempt still logs.
vi.mock("../api/client", async () => {
	const actual = await vi.importActual<typeof import("../api/client")>("../api/client");
	return {
		...actual,
		api: {
			get: vi.fn(() => Promise.reject(new Error("no network in unit tests"))),
			post: vi.fn(),
			patch: vi.fn(),
			del: vi.fn(),
		},
		setTokenGetter: vi.fn(),
	};
});

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
		// What useNote hands back for the routed note id. `useNote` keeps the
		// PREVIOUS note's data while the next one loads, so this can legitimately
		// be a different note than the URL names — see the auto-expand test.
		activeNote: undefined as unknown,
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
		// `useVaultTree` is deliberately NOT stubbed. It used to be pinned to
		// `{ data: undefined }`, which meant FolderTree's real call to it was never
		// exercised anywhere and a broken tree seam sailed through this file into
		// CI. It runs for real here (no active vault id in these tests, so it stays
		// `enabled: false` and never fetches — FolderTree only mounts it for its
		// observer, not its data).
		//
		// The hooks below ARE stubbed, so this file proves COMPOSITION only: no
		// tree payload can reach a row through them. The end-to-end path —
		// FolderTree rendering folder/note/attachment rows derived from a real
		// /vault/tree payload, in one request — is exercised against the real
		// hooks in api/vault-tree.test.tsx ("FolderTree renders from a real
		// /vault/tree payload"). Do not let that be deleted and leave this file
		// as the only coverage.
		useAttachments: () => ({ data: mock.attachments, isLoading: false }),
		useNote: () => ({ data: mock.activeNote, isLoading: false, error: null }),
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
	mock.activeNote = undefined;
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

	it("outlines the right-clicked row while its menu is open, and clears after", async () => {
		renderTree();
		const projects = await screen.findByRole("treeitem", { name: "Projects" });
		expect(projects.className).not.toMatch(/ring-2/u);

		fireEvent.contextMenu(projects, { clientX: 50, clientY: 60 });
		await screen.findByRole("menu");
		expect(screen.getByRole("treeitem", { name: "Projects" }).className).toMatch(/ring-2/u);

		// Escape closes the menu; the outline goes with it. ContextMenu listens on
		// `document`, and an event fired at `window` never reaches it.
		fireEvent.keyDown(document, { key: "Escape" });
		await waitFor(() => expect(screen.queryByRole("menu")).not.toBeInTheDocument());
		expect(screen.getByRole("treeitem", { name: "Projects" }).className).not.toMatch(/ring-2/u);
	});

	// Creation targets the RIGHT-CLICKED folder, not the toolbar's active one —
	// that difference is the whole point of putting them on the menu.
	it("creates a note inside the right-clicked folder", async () => {
		renderTree();
		const projects = await screen.findByRole("treeitem", { name: "Projects" });
		fireEvent.contextMenu(projects, { clientX: 50, clientY: 60 });
		fireEvent.click(await screen.findByRole("menuitem", { name: "New note here" }));
		// The id is minted client-side so the optimistic row is addressable at once.
		expect(createNoteMutate).toHaveBeenCalledWith(
			expect.objectContaining({ folder: "Projects", id: expect.any(String) }),
		);
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

	// Right-clicking empty tree space targets the vault root.
	describe("empty-space context menu", () => {
		const openRootMenu = async () => {
			renderTree();
			const tree = await screen.findByTestId("folder-tree-root");
			fireEvent.contextMenu(tree, { clientX: 10, clientY: 200 });
			await screen.findByRole("menu");
		};

		it("offers creation actions only", async () => {
			await openRootMenu();
			expect(screen.getByRole("menuitem", { name: "New note" })).toBeInTheDocument();
			expect(screen.getByRole("menuitem", { name: "New folder" })).toBeInTheDocument();
			// The root isn't a folder you can address.
			for (const label of ["Rename", "Move to…", "Delete"]) {
				expect(screen.queryByRole("menuitem", { name: label })).not.toBeInTheDocument();
			}
		});

		it("creates a note at the vault root", async () => {
			await openRootMenu();
			fireEvent.click(screen.getByRole("menuitem", { name: "New note" }));
			expect(createNoteMutate).toHaveBeenCalledWith(
				expect.objectContaining({ folder: "", id: expect.any(String) }),
			);
		});

		it("creates a folder at the root and opens it in rename mode", async () => {
			createdFolder.path = "untitled";
			mock.folders = [{ id: "7", parent_id: null, name: "untitled", count: 0 }];
			await openRootMenu();
			fireEvent.click(screen.getByRole("menuitem", { name: "New folder" }));
			expect(createFolderMutate).toHaveBeenCalledWith({ parent: "" });

			const input = (await screen.findByRole("textbox", {
				name: "Rename folder",
			})) as HTMLInputElement;
			expect(input).toHaveValue("untitled");
			expect(input.selectionEnd).toBe("untitled".length);
			createdFolder.path = "Projects/untitled";
		});

		// A row right-click must not fall through to the container, or the row's
		// menu would be replaced by the root one the moment it opened.
		it("does not fire when right-clicking a row", async () => {
			renderTree();
			const projects = await screen.findByRole("treeitem", { name: "Projects" });
			fireEvent.contextMenu(projects, { clientX: 50, clientY: 60 });
			await screen.findByRole("menu");
			expect(screen.getByRole("menuitem", { name: "Rename" })).toBeInTheDocument();
			expect(screen.queryByRole("menuitem", { name: "New folder" })).not.toBeInTheDocument();
		});
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

	// The auto-expand effect fires ONCE per selected note id. `useNote` keeps the
	// previous note's data on screen while the next one loads, so for a moment
	// the routed id and the loaded note disagree — spending the one shot on the
	// stale note expands the wrong ancestry and latches the right one out.
	it("auto-expands the folder of the routed note, not of a stale one", async () => {
		// The URL already points at Projects/spec.md; the loaded note is still the
		// one the user came from, which lives somewhere else entirely.
		mock.activeNote = { ...DEFAULT_ROOT_NOTE, id: "7", path: "archive/old.md", folder: "archive" };
		const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
		qc.setQueryData(["folder-notes-by-id", "", "root"], mock.rootNotes);
		// The loader reads note children from the cache, not from the hook — seed
		// Projects' one note so an expand actually renders a row.
		qc.setQueryData(
			["folder-notes-by-id", "", "1"],
			[{ ...DEFAULT_ROOT_NOTE, id: "99", path: "Projects/spec.md", title: "spec" }],
		);
		// A fresh element each time: re-rendering the SAME element object lets
		// React bail out of the subtree entirely, so the effect would never see
		// the arriving note.
		const treeFor = () => (
			<QueryClientProvider client={qc}>
				<MemoryRouter initialEntries={["/my-vault/99"]}>
					<Routes>
						<Route
							path="/:slug/:itemId"
							element={
								<FolderTreeProvider>
									<FolderTree />
								</FolderTreeProvider>
							}
						/>
					</Routes>
				</MemoryRouter>
			</QueryClientProvider>
		);
		const { rerender } = render(treeFor());
		await screen.findByRole("treeitem", { name: "Projects" });

		// The real note lands. Its folder is the one that has to open.
		mock.activeNote = {
			...DEFAULT_ROOT_NOTE,
			id: "99",
			path: "Projects/spec.md",
			folder: "Projects",
		};
		rerender(treeFor());

		await waitFor(() =>
			expect(screen.getByRole("treeitem", { name: "Projects" })).toHaveAttribute(
				"aria-expanded",
				"true",
			),
		);
		// ...and the one it came from was never opened on its behalf.
		expect(screen.getByRole("treeitem", { name: "archive" })).toHaveAttribute(
			"aria-expanded",
			"false",
		);
	});
});
