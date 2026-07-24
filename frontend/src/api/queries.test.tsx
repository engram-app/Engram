import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, renderHook, waitFor } from "@testing-library/react";
import type React from "react";
import { afterEach, beforeEach, describe, expect, expectTypeOf, it, vi } from "vitest";
import { ApiError } from "./client";
import { CrdtOpError } from "./crdt-ops";
import {
	type Folder,
	type Note,
	useAcceptTerms,
	useAttachments,
	useBatchDeleteAttachments,
	useBatchDeleteFolders,
	useBatchDeleteNotes,
	useBatchMoveAttachments,
	useBatchMoveFolders,
	useBatchMoveNotes,
	useCancelSubscription,
	useConfirmPlanChange,
	useCreateNote,
	useDeleteFolder,
	useDeleteNote,
	useDuplicateNote,
	useFolderNotesById,
	useFolders,
	useNote,
	usePlanChangePreview,
	useRenameAttachment,
	useRenameFolder,
	useRenameNote,
	useReverseCancel,
	useSearch,
	useUploadAttachment,
} from "./queries";

vi.mock("sonner", () => ({
	toast: {
		error: vi.fn(),
		success: vi.fn(),
		info: vi.fn(),
	},
}));

// queries.ts pulls useNavigate from react-router (useCreateNote). Stub it so
// the hooks render without a Router in these unit tests.
vi.mock("react-router", () => ({ useNavigate: () => () => {} }));

// Pin the active vault id so cache keys are deterministic for the
// optimistic-update tests below. The hook reads from a module-scoped
// store + localStorage; setting localStorage before module import is
// brittle, so we mock the hook directly.
vi.mock("./active-vault", async () => {
	const actual = await vi.importActual<typeof import("./active-vault")>("./active-vault");
	return { ...actual, useActiveVaultId: () => "42" };
});

const { get, post, del } = vi.hoisted(() => ({
	get: vi.fn(),
	post: vi.fn(),
	del: vi.fn(),
}));

// Note create/delete now ride the CRDT channel, not REST. Mock the channel ops
// (crdtCreateNote echoes its minted doc_id back on success — the ok reply's
// doc_id equals the id we sent).
const { crdtCreateNote, crdtDeleteNote, crdtCreateNoteWithContent } = vi.hoisted(() => ({
	crdtCreateNote: vi.fn((docId: string, _path: string) => Promise.resolve(docId)),
	crdtDeleteNote: vi.fn((docId: string) => Promise.resolve({ doc_id: docId })),
	crdtCreateNoteWithContent: vi.fn((docId: string, _path: string, _md: string) =>
		Promise.resolve(docId),
	),
}));
vi.mock("./channel", () => ({ crdtCreateNote, crdtDeleteNote, crdtCreateNoteWithContent }));
vi.mock("./client", async () => {
	const actual = await vi.importActual<typeof import("./client")>("./client");
	return {
		...actual,
		api: { get, post, patch: vi.fn(), del },
		setTokenGetter: vi.fn(),
	};
});

let qc: QueryClient;

beforeEach(() => {
	get.mockReset();
	post.mockReset();
	del.mockReset();
	crdtCreateNote.mockReset().mockImplementation((docId: string) => Promise.resolve(docId));
	crdtDeleteNote
		.mockReset()
		.mockImplementation((docId: string) => Promise.resolve({ doc_id: docId }));
	crdtCreateNoteWithContent
		.mockReset()
		.mockImplementation((docId: string) => Promise.resolve(docId));
	qc = new QueryClient();
});

afterEach(() => {
	qc.clear();
});

function wrapper({ children }: { children: React.ReactNode }) {
	return <QueryClientProvider client={qc}>{children}</QueryClientProvider>;
}

describe("useAcceptTerms", () => {
	it("awaits onboarding/status refetch before mutateAsync resolves", async () => {
		// Seed the cache so invalidate triggers a refetch instead of a no-op.
		qc.setQueryData(["onboarding", "status"], { next_step: "agreement", enabled: true });

		let invalidateResolved = false;
		const invalidateSpy = vi.spyOn(qc, "invalidateQueries").mockImplementation(async () => {
			await new Promise((r) => setTimeout(r, 20));
			invalidateResolved = true;
		});

		post.mockResolvedValue({ version: "v2.0", accepted_at: "2026-06-01T00:00:00Z" });

		const { result } = renderHook(() => useAcceptTerms(), { wrapper });

		await act(async () => {
			await result.current.mutateAsync({
				tos_version: "v2.0",
				tos_hash: "th",
				privacy_version: "v1.0",
				privacy_hash: "ph",
			});
		});

		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["onboarding", "status"] });
		// If onSuccess fires-and-forgets, this would still be false when mutateAsync resolves
		// and the user would be navigated with a stale cache (bug: double-accept).
		expect(invalidateResolved).toBe(true);
	});
});

describe("inline billing mutations", () => {
	it("useCancelSubscription POSTs and invalidates billing caches", async () => {
		post.mockResolvedValue({ scheduled_change: { effective_at: "2026-07-01T00:00:00Z" } });
		const invalidateSpy = vi.spyOn(qc, "invalidateQueries");

		const { result } = renderHook(() => useCancelSubscription(), { wrapper });
		await act(async () => {
			await result.current.mutateAsync();
		});

		expect(post).toHaveBeenCalledWith("/billing/cancel-subscription");
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["billing", "status"] });
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["billing", "subscription"] });
	});

	it("useReverseCancel POSTs and invalidates billing caches", async () => {
		post.mockResolvedValue({ scheduled_change: null });
		const invalidateSpy = vi.spyOn(qc, "invalidateQueries");

		const { result } = renderHook(() => useReverseCancel(), { wrapper });
		await act(async () => {
			await result.current.mutateAsync();
		});

		expect(post).toHaveBeenCalledWith("/billing/reverse-cancel");
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["billing", "status"] });
	});

	it("useConfirmPlanChange forwards target_price_id and invalidates caches", async () => {
		post.mockResolvedValue({ transaction_id: "txn_xyz" });
		const invalidateSpy = vi.spyOn(qc, "invalidateQueries");

		const { result } = renderHook(() => useConfirmPlanChange(), { wrapper });
		await act(async () => {
			await result.current.mutateAsync("pri_new");
		});

		expect(post).toHaveBeenCalledWith("/billing/plan-change/confirm", {
			target_price_id: "pri_new",
		});
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["billing", "subscription"] });
	});

	it("usePlanChangePreview stays disabled until a target is selected", () => {
		const { result } = renderHook(() => usePlanChangePreview(null), { wrapper });
		// No fetch happens for null target — query is disabled.
		expect(post).not.toHaveBeenCalled();
		expect(result.current.fetchStatus).toBe("idle");
	});
});

describe("useNote by id", () => {
	it("fetches /notes/by-id/:id and caches by id", async () => {
		get.mockResolvedValue({
			id: "42",
			path: "a.md",
			title: "A",
			folder: "",
			tags: [],
			version: 1,
			content: "# A",
			mtime: "s",
			created_at: "s",
			updated_at: "s",
		} as Note);
		const { result } = renderHook(() => useNote("42"), { wrapper });
		await waitFor(() => expect(result.current.isSuccess).toBe(true));
		expect(get).toHaveBeenCalledWith("/notes/by-id/42");
	});

	it("is disabled when id is null", () => {
		const { result } = renderHook(() => useNote(null), { wrapper });
		expect(result.current.fetchStatus).toBe("idle");
		expect(get).not.toHaveBeenCalled();
	});
});

describe("useRenameNote", () => {
	it("sends crdt_create with the note id at the new path (rename-as-move) + invalidates", async () => {
		const invalidateSpy = vi.spyOn(qc, "invalidateQueries");

		const { result } = renderHook(() => useRenameNote(), { wrapper });
		await act(async () => {
			await result.current.mutateAsync({ id: "n1", old_path: "a/x.md", new_path: "b/y.md" });
		});

		// Rename/move = crdt_create for a KNOWN id at a new free path (backend
		// relocates the row in place). No REST /notes/rename.
		expect(crdtCreateNote).toHaveBeenCalledWith("n1", "b/y.md");
		expect(post).not.toHaveBeenCalledWith("/notes/rename", expect.anything());
		// onSettled scopes invalidation by vault — broader keys would
		// touch other vaults' caches needlessly.
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["folders", "42"] });
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["folderNotes", "42"] });
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["note", "42"] });
	});

	it("surfaces create_failed (target path occupied) to the caller", async () => {
		crdtCreateNote.mockRejectedValue(new CrdtOpError("create_failed", "crdt_create"));

		const { result } = renderHook(() => useRenameNote(), { wrapper });
		await expect(
			result.current.mutateAsync({ id: "n1", old_path: "a.md", new_path: "b.md" }),
		).rejects.toMatchObject({ reason: "create_failed" });
	});
});

describe("useRenameFolder", () => {
	it("POSTs /folders/rename and invalidates folders + folder lists", async () => {
		post.mockResolvedValue({ renamed: true, old_path: "a", new_path: "b", count: 3 });
		const invalidateSpy = vi.spyOn(qc, "invalidateQueries");

		const { result } = renderHook(() => useRenameFolder(), { wrapper });
		await act(async () => {
			await result.current.mutateAsync({ old_path: "a", new_path: "b" });
		});

		expect(post).toHaveBeenCalledWith("/folders/rename", {
			old_path: "a",
			new_path: "b",
		});
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["folders", "42"] });
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["folderNotes", "42"] });
	});

	it("surfaces 409 as ApiError", async () => {
		post.mockRejectedValue(new ApiError(409, "conflict"));

		const { result } = renderHook(() => useRenameFolder(), { wrapper });
		await expect(
			result.current.mutateAsync({ old_path: "a", new_path: "b" }),
		).rejects.toMatchObject({ status: 409 });
	});
});

describe("useDeleteNote", () => {
	it("sends crdt_delete by id and invalidates folders + folder list + note", async () => {
		const invalidateSpy = vi.spyOn(qc, "invalidateQueries");

		const { result } = renderHook(() => useDeleteNote(), { wrapper });
		await act(async () => {
			await result.current.mutateAsync({ id: "42", path: "foo bar/x y.md" });
		});

		// Delete rides the CRDT channel by id (parity with the plugin) — the
		// server owns path/folder lookups, so the client just supplies the id.
		expect(crdtDeleteNote).toHaveBeenCalledWith("42");
		expect(del).not.toHaveBeenCalled();
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["folders", "42"] });
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["folderNotes", "42"] });
		// onMutate invalidates (not removes) the note's cache, keyed by id, so a
		// mounted useNote(id) observer on the open note reconnects instead of
		// orphaning on a destroyed Query object.
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["note", "42", "42"] });
	});

	it("surfaces a rejected crdt_delete (e.g. disconnected) to the caller", async () => {
		crdtDeleteNote.mockRejectedValue(new CrdtOpError("disconnected", "crdt_delete"));

		const { result } = renderHook(() => useDeleteNote(), { wrapper });
		await expect(result.current.mutateAsync({ id: "7", path: "gone.md" })).rejects.toMatchObject({
			reason: "disconnected",
		});
	});
});

describe("useDuplicateNote", () => {
	it("GETs source content then genesis-creates the copy at new_path (no POST /notes)", async () => {
		get.mockResolvedValue({ path: "a.md", content: "hello world" });
		const invalidateSpy = vi.spyOn(qc, "invalidateQueries");

		const { result } = renderHook(() => useDuplicateNote(), { wrapper });
		await act(async () => {
			await result.current.mutateAsync({ src_path: "a.md", new_path: "a (copy).md" });
		});

		expect(get).toHaveBeenCalledWith("/notes/a.md");
		// Copy content genesis-created over the crdt channel at the new path.
		expect(crdtCreateNoteWithContent).toHaveBeenCalledWith(
			expect.any(String),
			"a (copy).md",
			"hello world",
		);
		expect(post).not.toHaveBeenCalledWith("/notes", expect.anything());
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["folders", "42"] });
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["folderNotes", "42"] });
	});

	it("surfaces create_failed (target occupied) so callers can toast", async () => {
		get.mockResolvedValue({ content: "x" });
		crdtCreateNoteWithContent.mockRejectedValue(
			new CrdtOpError("create_failed", "crdt_create_batch"),
		);

		const { result } = renderHook(() => useDuplicateNote(), { wrapper });
		await expect(
			result.current.mutateAsync({ src_path: "a.md", new_path: "a (copy).md" }),
		).rejects.toMatchObject({ reason: "create_failed" });
	});

	it("mirrors the optimistic placeholder into the tree by-id list", async () => {
		qc.setQueryData(["folders", "42"], {
			folders: [{ id: "f9", parent_id: null, name: "dst", count: 1 }],
		});
		seedFolderNotesById("f9", [{ id: "a", path: "dst/a.md" }]);
		qc.setQueryData(["folderNotes", "42", "dst"], { notes: [] });

		get.mockResolvedValue({ content: "x" });
		let resolveCreate: () => void = () => {};
		crdtCreateNoteWithContent.mockReturnValue(
			new Promise((r) => {
				resolveCreate = () => r("real-dup");
			}),
		);

		const { result } = renderHook(() => useDuplicateNote(), { wrapper });
		act(() => {
			result.current.mutate({ src_path: "dst/a.md", new_path: "dst/a copy.md" });
		});

		await waitFor(() => {
			const byId = qc.getQueryData<Array<{ id: string; path: string }>>([
				"folder-notes-by-id",
				"42",
				"f9",
			]);
			expect(byId?.some((n) => n.path === "dst/a copy.md")).toBe(true);
		});

		resolveCreate();

		// After success the placeholder id is swapped for the minted doc_id.
		await waitFor(() => {
			const byId = qc.getQueryData<Array<{ id: string }>>(["folder-notes-by-id", "42", "f9"]);
			expect(byId?.some((n) => n.id === "real-dup")).toBe(true);
		});
	});
});

describe("useDeleteFolder", () => {
	it("DELETEs encoded folder path and invalidates folders + folder lists", async () => {
		del.mockResolvedValue({ deleted: true });
		const invalidateSpy = vi.spyOn(qc, "invalidateQueries");

		const { result } = renderHook(() => useDeleteFolder(), { wrapper });
		await act(async () => {
			await result.current.mutateAsync({ path: "my folder/sub" });
		});

		expect(del).toHaveBeenCalledWith("/folders/my%20folder/sub");
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["folders", "42"] });
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["folderNotes", "42"] });
	});

	it("surfaces backend errors as ApiError", async () => {
		del.mockRejectedValue(new ApiError(404, "not found"));

		const { result } = renderHook(() => useDeleteFolder(), { wrapper });
		await expect(result.current.mutateAsync({ path: "gone" })).rejects.toMatchObject({
			status: 404,
		});
	});
});

// ── Optimistic-update behaviour ──────────────────────────────
//
// These tests don't assert on network calls — that's the responsibility
// of the per-mutation specs above. They lock in the snappy-UI contract:
// caches mutate synchronously on `onMutate`, and `onError` restores the
// pre-mutation snapshot so a rejected request leaves no visible trace.

function seedFolderNotes(
	folder: string,
	notes: Partial<{ id: string; path: string; title: string }>[],
) {
	qc.setQueryData(["folderNotes", "42", folder], {
		notes: notes.map((n, i) => ({
			id: n.id ?? String(i + 1),
			path: n.path ?? "",
			title: n.title ?? "",
			folder,
			tags: [],
			version: 1,
			mtime: "",
			created_at: "",
			updated_at: "",
		})),
	});
}

function seedFolders(folders: Array<{ name: string; count: number }>) {
	qc.setQueryData(["folders", "42"], { folders });
}

describe("optimistic rename note", () => {
	it("removes the note from the old folder cache and inserts into the new folder before the network resolves", async () => {
		seedFolderNotes("a", [{ path: "a/x.md", title: "X" }]);
		seedFolderNotes("b", []);
		seedFolders([
			{ name: "a", count: 1 },
			{ name: "b", count: 0 },
		]);

		// Hold crdt_create so we can inspect the optimistic state.
		let resolveRename: () => void = () => {};
		crdtCreateNote.mockReturnValue(
			new Promise((r) => {
				resolveRename = () => r("n1");
			}),
		);

		const { result } = renderHook(() => useRenameNote(), { wrapper });
		act(() => {
			result.current.mutate({ id: "n1", old_path: "a/x.md", new_path: "b/x.md" });
		});

		await waitFor(() => {
			const oldList = qc.getQueryData<{ notes: Array<{ path: string }> }>([
				"folderNotes",
				"42",
				"a",
			]);
			expect(oldList?.notes.map((n) => n.path)).toEqual([]);
		});

		const newList = qc.getQueryData<{ notes: Array<{ path: string }> }>(["folderNotes", "42", "b"]);
		expect(newList?.notes.map((n) => n.path)).toContain("b/x.md");

		const folders = qc.getQueryData<{ folders: Array<{ name: string; count: number }> }>([
			"folders",
			"42",
		]);
		expect(folders?.folders.find((f) => f.name === "a")?.count).toBe(0);
		expect(folders?.folders.find((f) => f.name === "b")?.count).toBe(1);

		// Settle the promise so React Query unwinds cleanly.
		resolveRename();
	});

	it("restores the pre-mutation cache snapshot when the mutation rejects", async () => {
		seedFolderNotes("a", [{ path: "a/x.md", title: "X" }]);
		seedFolderNotes("b", []);
		seedFolders([
			{ name: "a", count: 1 },
			{ name: "b", count: 0 },
		]);

		crdtCreateNote.mockRejectedValue(new CrdtOpError("create_failed", "crdt_create"));

		const { result } = renderHook(() => useRenameNote(), { wrapper });
		await act(async () => {
			try {
				await result.current.mutateAsync({ id: "n1", old_path: "a/x.md", new_path: "b/x.md" });
			} catch {
				// Expected — we want the rollback.
			}
		});

		const oldList = qc.getQueryData<{ notes: Array<{ path: string }> }>(["folderNotes", "42", "a"]);
		expect(oldList?.notes.map((n) => n.path)).toEqual(["a/x.md"]);

		const newList = qc.getQueryData<{ notes: Array<{ path: string }> }>(["folderNotes", "42", "b"]);
		expect(newList?.notes.map((n) => n.path)).toEqual([]);

		const folders = qc.getQueryData<{ folders: Array<{ name: string; count: number }> }>([
			"folders",
			"42",
		]);
		expect(folders?.folders.find((f) => f.name === "a")?.count).toBe(1);
		expect(folders?.folders.find((f) => f.name === "b")?.count).toBe(0);
	});
});

describe("optimistic delete note", () => {
	it("removes the note from the folder cache before the request resolves", async () => {
		seedFolderNotes("", [
			{ id: "1", path: "gone.md", title: "Gone" },
			{ id: "2", path: "stays.md", title: "Stays" },
		]);
		seedFolders([{ name: "", count: 2 }]);

		let resolveDel!: (v: { doc_id: string }) => void;
		crdtDeleteNote.mockReturnValue(
			new Promise((r) => {
				resolveDel = r;
			}),
		);

		const { result } = renderHook(() => useDeleteNote(), { wrapper });
		act(() => {
			result.current.mutate({ id: "1", path: "gone.md" });
		});

		await waitFor(() => {
			const list = qc.getQueryData<{ notes: Array<{ path: string }> }>(["folderNotes", "42", ""]);
			expect(list?.notes.map((n) => n.path)).toEqual(["stays.md"]);
		});

		resolveDel({ doc_id: "1" });
	});

	it("restores the cache when the delete fails", async () => {
		seedFolderNotes("", [
			{ id: "1", path: "gone.md", title: "Gone" },
			{ id: "2", path: "stays.md", title: "Stays" },
		]);
		seedFolders([{ name: "", count: 2 }]);

		crdtDeleteNote.mockRejectedValue(new CrdtOpError("disconnected", "crdt_delete"));

		const { result } = renderHook(() => useDeleteNote(), { wrapper });
		await act(async () => {
			try {
				await result.current.mutateAsync({ id: "1", path: "gone.md" });
			} catch {
				// expected
			}
		});

		const list = qc.getQueryData<{ notes: Array<{ path: string }> }>(["folderNotes", "42", ""]);
		expect(list?.notes.map((n) => n.path).sort()).toEqual(["gone.md", "stays.md"]);
	});
});

// ── Id-stable optimistic updates (URL-by-id Task 9) ─────────
//
// Notes are cached by id (`['note', vaultId, id]`). On rename, the
// id never changes — only `path` / `folder` shift. The cache entry
// must update in place under the same key; the prior path-keyed
// shuffle (write to new key + remove old) is dead.

function seedNoteById(id: string, note: Partial<Note>) {
	qc.setQueryData(["note", "42", id], {
		id,
		path: "",
		title: "",
		folder: "",
		tags: [],
		version: 1,
		content: "",
		mtime: "s",
		created_at: "s",
		updated_at: "s",
		...note,
	} satisfies Note);
}

describe("rename note does NOT re-path the note body cache optimistically", () => {
	// The open editor keys its CRDT doc on `note.path`. Re-pathing `['note', id]`
	// before the rename commits makes the editor enroll the new path early, which
	// the CRDT channel bootstraps into a duplicate note that then 409s the rename
	// (a stable cross-tab duplicate under load). The note cache must stay on the
	// old path until onSettled's refetch confirms the server move.
	it("leaves [note, vaultId, id] on the old path while the rename is in flight", async () => {
		seedFolderNotes("a", [{ id: "42", path: "a/x.md", title: "X" }]);
		seedFolderNotes("b", []);
		seedFolders([
			{ name: "a", count: 1 },
			{ name: "b", count: 0 },
		]);
		seedNoteById("42", { id: "42", path: "a/x.md", folder: "a", title: "X", content: "# X" });

		let resolvePost!: (v: unknown) => void;
		post.mockReturnValue(
			new Promise((r) => {
				resolvePost = r;
			}),
		);

		const { result } = renderHook(() => useRenameNote(), { wrapper });
		act(() => {
			result.current.mutate({ id: "n1", old_path: "a/x.md", new_path: "b/y.md" });
		});

		// The FOLDER lists flip optimistically (snappy tree)…
		await waitFor(() => {
			const oldList = qc.getQueryData<{ notes: Array<{ path: string }> }>([
				"folderNotes",
				"42",
				"a",
			]);
			expect(oldList?.notes.map((n) => n.path)).toEqual([]);
		});
		// …but the note body cache stays on the OLD path (no early CRDT re-enroll).
		const cached = qc.getQueryData<Note>(["note", "42", "42"]);
		expect(cached?.path).toBe("a/x.md");
		expect(cached?.folder).toBe("a");
		expect(cached?.content).toBe("# X");

		resolvePost({
			renamed: true,
			old_path: "a/x.md",
			new_path: "b/y.md",
			note: { id: "42", path: "b/y.md" },
		});
	});
});

describe("rename folder does NOT re-path cached child notes optimistically", () => {
	it("leaves cached [note, vaultId, *] under the old prefix untouched while in flight", async () => {
		qc.setQueryData(["folders", "42"], {
			folders: [
				{ name: "src", count: 2 },
				{ name: "src/sub", count: 1 },
			],
		});
		seedNoteById("10", { id: "10", path: "src/a.md", folder: "src" });
		seedNoteById("11", { id: "11", path: "src/sub/b.md", folder: "src/sub" });
		seedNoteById("99", { id: "99", path: "other/c.md", folder: "other" });

		let resolvePost!: (v: unknown) => void;
		post.mockReturnValue(
			new Promise((r) => {
				resolvePost = r;
			}),
		);

		const { result } = renderHook(() => useRenameFolder(), { wrapper });
		act(() => {
			result.current.mutate({ old_path: "src", new_path: "dst" });
		});

		// The folders cache renames optimistically…
		await waitFor(() => {
			const folders = qc.getQueryData<{ folders: Folder[] }>(["folders", "42"]);
			expect(folders?.folders.some((f) => f.name === "dst")).toBe(true);
		});
		// …but child note caches keep their old paths (no early CRDT re-enroll).
		expect(qc.getQueryData<Note>(["note", "42", "10"])?.path).toBe("src/a.md");
		expect(qc.getQueryData<Note>(["note", "42", "11"])?.path).toBe("src/sub/b.md");
		expect(qc.getQueryData<Note>(["note", "42", "99"])?.path).toBe("other/c.md");

		resolvePost({ renamed: true, old_path: "src", new_path: "dst", count: 2 });
	});
});

// ── useFolders surfaces id + parent_id (Headless Tree Task 17) ────
//
// Backend `GET /api/folders` returns `{folders: [{id, name, count,
// parent_id}, ...]}` (commit 935b7bbf). The headless-tree consumer
// keys nodes by id and discovers tree shape via parent_id, so the
// Folder type and the parsed query data must surface both fields
// verbatim. `name` continues to carry the FULL folder path — that
// shape is load-bearing for existing consumers and stays.

describe("useFolderNotesById", () => {
	it("fetches notes for the given folder id", async () => {
		get.mockResolvedValue({
			notes: [
				{
					id: "100",
					path: "foo/a.md",
					title: "A",
					folder: "foo",
					tags: [],
					version: 1,
					mtime: "s",
					created_at: "s",
					updated_at: "s",
				},
			],
		});

		const { result } = renderHook(() => useFolderNotesById("42"), { wrapper });
		await waitFor(() => expect(result.current.data).toBeDefined());

		expect(get).toHaveBeenCalledWith("/folders/by-id/42/notes");
		expect(result.current.data?.[0]).toMatchObject({
			id: expect.any(String),
			path: expect.any(String),
		});
	});

	it("disabled when folderId is null", () => {
		const { result } = renderHook(() => useFolderNotesById(null), { wrapper });
		expect(result.current.fetchStatus).toBe("idle");
		expect(get).not.toHaveBeenCalled();
	});
});

describe("Folder type", () => {
	it("exposes id (string), parent_id (string | null), name (string), count (number)", () => {
		expectTypeOf<Folder>().toMatchTypeOf<{
			id: string;
			parent_id: string | null;
			name: string;
			count: number;
		}>();
	});
});

describe("useFolders", () => {
	it("passes through id + parent_id from the backend response", async () => {
		get.mockResolvedValue({
			folders: [
				{ id: "7", parent_id: null, name: "top", count: 2 },
				{ id: "8", parent_id: "7", name: "top/sub", count: 1 },
			],
		});

		const { result } = renderHook(() => useFolders(), { wrapper });
		await waitFor(() => expect(result.current.data).toBeDefined());

		expect(get).toHaveBeenCalledWith("/folders");
		const folders = result.current.data ?? [];
		expect(folders).toHaveLength(2);
		expect(folders[0]).toMatchObject({
			id: "7",
			parent_id: null,
			name: "top",
			count: 2,
		});
		expect(folders[1]).toMatchObject({
			id: "8",
			parent_id: "7",
			name: "top/sub",
			count: 1,
		});
	});
});

// ── Batch mutation hooks (Task 19) ────────────────────────────
//
// Four hooks mirroring the single-target rename/delete pattern but
// targeting the backend's atomic /batch-{delete,move} endpoints. Each:
//   1. Sends a UUID `X-Idempotency-Key` header (backend dedupes via the
//      IdempotencyKey plug installed Tasks 7/8).
//   2. Patches every affected cache slice in `onMutate` so the UI moves
//      instantly — important for tree multi-select where the user just
//      ctrl-clicked five rows and hit delete.
//   3. Rolls those patches back on error.
//   4. Invalidates `['folders']` + `['folder-notes-by-id']` on success
//      so the server is the eventual source of truth (and so any
//      server-side cascade we don't model client-side gets reconciled).

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;

function seedFolderNotesById(
	folderId: string,
	notes: Array<{ id: string; path?: string; folder?: string }>,
) {
	qc.setQueryData(
		["folder-notes-by-id", "42", folderId],
		notes.map((n) => ({
			id: n.id,
			path: n.path ?? `f${folderId}/n${n.id}.md`,
			title: `n${n.id}`,
			folder: n.folder ?? `f${folderId}`,
			tags: [],
			version: 1,
			mtime: "",
			created_at: "",
			updated_at: "",
		})),
	);
}

describe("useBatchDeleteNotes", () => {
	it("sends one crdt_delete per id (no batch REST call)", async () => {
		const { result } = renderHook(() => useBatchDeleteNotes(), { wrapper });
		await act(async () => {
			await result.current.mutateAsync({ ids: ["1", "2"] });
		});

		expect(crdtDeleteNote).toHaveBeenCalledWith("1");
		expect(crdtDeleteNote).toHaveBeenCalledWith("2");
		expect(crdtDeleteNote).toHaveBeenCalledTimes(2);
		expect(post).not.toHaveBeenCalled();
	});

	it("optimistically removes ids from every cached folder-notes-by-id list", async () => {
		seedFolderNotesById("5", [{ id: "1" }, { id: "2" }, { id: "3" }]);
		seedFolderNotesById("6", [{ id: "4" }]);

		let resolveDeletes: () => void = () => {};
		crdtDeleteNote.mockReturnValue(
			new Promise((r) => {
				resolveDeletes = () => r({ doc_id: "x" });
			}),
		);

		const { result } = renderHook(() => useBatchDeleteNotes(), { wrapper });
		act(() => {
			result.current.mutate({ ids: ["1", "2", "4"] });
		});

		await waitFor(() => {
			const list5 = qc.getQueryData<Array<{ id: string }>>(["folder-notes-by-id", "42", "5"]);
			expect(list5?.map((n) => n.id)).toEqual(["3"]);
		});

		const list6 = qc.getQueryData<Array<{ id: string }>>(["folder-notes-by-id", "42", "6"]);
		expect(list6?.map((n) => n.id)).toEqual([]);

		resolveDeletes();
	});

	it("rolls back every patched list when a delete rejects", async () => {
		seedFolderNotesById("5", [{ id: "1" }, { id: "2" }, { id: "3" }]);
		crdtDeleteNote.mockRejectedValue(new CrdtOpError("disconnected", "crdt_delete"));

		const { result } = renderHook(() => useBatchDeleteNotes(), { wrapper });
		await act(async () => {
			try {
				await result.current.mutateAsync({ ids: ["1", "2"] });
			} catch {
				// expected
			}
		});

		const list = qc.getQueryData<Array<{ id: string }>>(["folder-notes-by-id", "42", "5"]);
		expect(list?.map((n) => n.id).sort()).toEqual(["1", "2", "3"]);
	});

	it("invalidates folders + folder-notes-by-id on success", async () => {
		const invalidateSpy = vi.spyOn(qc, "invalidateQueries");

		const { result } = renderHook(() => useBatchDeleteNotes(), { wrapper });
		await act(async () => {
			await result.current.mutateAsync({ ids: ["1", "2"] });
		});

		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["folders", "42"] });
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["folder-notes-by-id", "42"] });
	});

	it("reconciles server truth even on a (partial) failure — Promise.all is not atomic", async () => {
		// A mid-batch reject leaves some ids already deleted server-side while
		// onError restores EVERY optimistically-removed row (including the gone
		// ones). Reconciliation must run on the failure path too, else the tree
		// shows phantom notes (404 on click) until an unrelated refetch.
		seedFolderNotesById("5", [{ id: "1" }, { id: "2" }]);
		crdtDeleteNote.mockRejectedValue(new CrdtOpError("rate_limited", "crdt_delete"));
		const invalidateSpy = vi.spyOn(qc, "invalidateQueries");

		const { result } = renderHook(() => useBatchDeleteNotes(), { wrapper });
		await act(async () => {
			try {
				await result.current.mutateAsync({ ids: ["1", "2"] });
			} catch {
				// expected
			}
		});

		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["folder-notes-by-id", "42"] });
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["folders", "42"] });
	});

	it("optimistically strips deleted root notes from the by-id root list", async () => {
		// Root notes share the one id-keyed cache under the 'root' sentinel.
		seedFolderNotesById("root", [
			{ id: "1", path: "a.md", folder: "" },
			{ id: "2", path: "b.md", folder: "" },
		]);

		let resolvePost!: (v: unknown) => void;
		post.mockReturnValue(
			new Promise((r) => {
				resolvePost = r;
			}),
		);

		const { result } = renderHook(() => useBatchDeleteNotes(), { wrapper });
		act(() => {
			result.current.mutate({ ids: ["1"] });
		});

		await waitFor(() => {
			const root = qc.getQueryData<Array<{ id: string }>>(["folder-notes-by-id", "42", "root"]);
			expect(root?.map((n) => n.id)).toEqual(["2"]);
		});

		resolvePost({ deleted: 1 });
	});

	it("rolls back the by-id root list when a delete rejects", async () => {
		seedFolderNotesById("root", [{ id: "1", path: "a.md", folder: "" }]);
		crdtDeleteNote.mockRejectedValue(new CrdtOpError("disconnected", "crdt_delete"));

		const { result } = renderHook(() => useBatchDeleteNotes(), { wrapper });
		await act(async () => {
			try {
				await result.current.mutateAsync({ ids: ["1"] });
			} catch {
				// expected
			}
		});

		const root = qc.getQueryData<Array<{ id: string }>>(["folder-notes-by-id", "42", "root"]);
		expect(root?.map((n) => n.id)).toEqual(["1"]);
	});
});

describe("useCreateNote — optimistic placeholder", () => {
	it('inserts a placeholder at root (by-id "root") then swaps it for the real note', async () => {
		// Root notes share the one id-keyed cache under the 'root' sentinel.
		qc.setQueryData(["folder-notes-by-id", "42", "root"], []);

		// Hold crdt_create pending so the optimistic placeholder is observable,
		// then resolve with the minted doc_id (the ok reply echoes the id we sent).
		let resolveCreate: () => void = () => {};
		crdtCreateNote.mockImplementation(
			(docId: string) =>
				new Promise<string>((r) => {
					resolveCreate = () => r(docId);
				}),
		);

		const { result } = renderHook(() => useCreateNote(), { wrapper });
		act(() => {
			result.current.mutate({ folder: "" });
		});

		await waitFor(() => {
			const root = qc.getQueryData<Array<{ id: string; title: string }>>([
				"folder-notes-by-id",
				"42",
				"root",
			]);
			expect(root).toHaveLength(1);
			expect(root?.[0]?.id).toMatch(/^optimistic-/u);
			expect(root?.[0]?.title).toBe("Untitled");
		});

		// A client-minted uuid7 is sent as the doc_id (not a v4/placeholder), at
		// the collision-bumped path.
		const [[mintedId] = []] = crdtCreateNote.mock.calls;
		expect(crdtCreateNote).toHaveBeenCalledWith(mintedId, "Untitled.md");
		expect(mintedId).not.toMatch(/^optimistic-/u);

		resolveCreate();

		await waitFor(() => {
			const root = qc.getQueryData<Array<{ id: string }>>(["folder-notes-by-id", "42", "root"]);
			expect(root?.[0]?.id).toBe(mintedId);
		});
	});

	it("inserts a placeholder into the by-id list for a subfolder", async () => {
		qc.setQueryData(["folders", "42"], {
			folders: [{ id: "f9", parent_id: null, name: "sub", count: 0 }],
		});
		qc.setQueryData(["folder-notes-by-id", "42", "f9"], []);

		let resolveCreate: () => void = () => {};
		crdtCreateNote.mockImplementation(
			(docId: string) =>
				new Promise<string>((r) => {
					resolveCreate = () => r(docId);
				}),
		);

		const { result } = renderHook(() => useCreateNote(), { wrapper });
		act(() => {
			result.current.mutate({ folder: "sub" });
		});

		await waitFor(() => {
			const byId = qc.getQueryData<Array<{ id: string }>>(["folder-notes-by-id", "42", "f9"]);
			expect(byId).toHaveLength(1);
			expect(byId?.[0]?.id).toMatch(/^optimistic-/u);
		});

		resolveCreate();

		await waitFor(() => {
			const byId = qc.getQueryData<Array<{ id: string }>>(["folder-notes-by-id", "42", "f9"]);
			const [[mintedId] = []] = crdtCreateNote.mock.calls;
			expect(byId?.[0]?.id).toBe(mintedId);
		});
	});

	it("bumps the name and retries when crdt_create fails with create_failed (path owned)", async () => {
		qc.setQueryData(["folder-notes-by-id", "42", "root"], []);
		// First attempt: the path is already owned → create_failed. Second attempt
		// (bumped name) succeeds by echoing its minted id.
		crdtCreateNote
			.mockRejectedValueOnce(new CrdtOpError("create_failed", "crdt_create"))
			.mockImplementation((docId: string) => Promise.resolve(docId));

		const { result } = renderHook(() => useCreateNote(), { wrapper });
		await act(async () => {
			await result.current.mutateAsync({ folder: "" });
		});

		expect(crdtCreateNote).toHaveBeenCalledTimes(2);
		expect(crdtCreateNote.mock.calls[0]![1]).toBe("Untitled.md");
		expect(crdtCreateNote.mock.calls[1]![1]).toBe("Untitled 1.md");
	});

	it("surfaces notes_cap_reached without retrying", async () => {
		qc.setQueryData(["folder-notes-by-id", "42", "root"], []);
		crdtCreateNote.mockRejectedValue(new CrdtOpError("notes_cap_reached", "crdt_create"));

		const { result } = renderHook(() => useCreateNote(), { wrapper });
		await expect(result.current.mutateAsync({ folder: "" })).rejects.toMatchObject({
			reason: "notes_cap_reached",
		});
		expect(crdtCreateNote).toHaveBeenCalledTimes(1);
	});
});

describe("useBatchMoveNotes", () => {
	it("sends one crdt_create per id at target_folder/basename (no batch REST)", async () => {
		const { result } = renderHook(() => useBatchMoveNotes(), { wrapper });
		await act(async () => {
			await result.current.mutateAsync({
				ids: ["1", "2"],
				target_folder: "dst",
				paths: { "1": "a/x.md", "2": "b/y.md" },
			});
		});

		expect(crdtCreateNote).toHaveBeenCalledWith("1", "dst/x.md");
		expect(crdtCreateNote).toHaveBeenCalledWith("2", "dst/y.md");
		expect(post).not.toHaveBeenCalled();
	});

	it("moves to the vault root as a bare basename", async () => {
		const { result } = renderHook(() => useBatchMoveNotes(), { wrapper });
		await act(async () => {
			await result.current.mutateAsync({
				ids: ["1"],
				target_folder: "",
				paths: { "1": "a/x.md" },
			});
		});
		expect(crdtCreateNote).toHaveBeenCalledWith("1", "x.md");
	});

	it("optimistically strips moved notes from source lists before resolution", async () => {
		seedFolderNotesById("5", [{ id: "1" }, { id: "2" }, { id: "3" }]);
		seedFolderNotesById("9", [{ id: "4" }]);

		let resolveMove: () => void = () => {};
		crdtCreateNote.mockReturnValue(
			new Promise((r) => {
				resolveMove = () => r("1");
			}),
		);

		const { result } = renderHook(() => useBatchMoveNotes(), { wrapper });
		act(() => {
			result.current.mutate({
				ids: ["1", "2"],
				target_folder: "dst",
				paths: { "1": "x.md", "2": "y.md" },
			});
		});

		await waitFor(() => {
			const src = qc.getQueryData<Array<{ id: string }>>(["folder-notes-by-id", "42", "5"]);
			expect(src?.map((n) => n.id)).toEqual(["3"]);
		});

		resolveMove();
	});

	it("rolls back source list when a move rejects (target occupied)", async () => {
		seedFolderNotesById("5", [{ id: "1" }, { id: "2" }, { id: "3" }]);
		crdtCreateNote.mockRejectedValue(new CrdtOpError("create_failed", "crdt_create"));

		const { result } = renderHook(() => useBatchMoveNotes(), { wrapper });
		await act(async () => {
			try {
				await result.current.mutateAsync({
					ids: ["1", "2"],
					target_folder: "dst",
					paths: { "1": "x.md", "2": "y.md" },
				});
			} catch {
				// expected
			}
		});

		const src = qc.getQueryData<Array<{ id: string }>>(["folder-notes-by-id", "42", "5"]);
		expect(src?.map((n) => n.id).sort()).toEqual(["1", "2", "3"]);
	});

	it("optimistically updates folder counts so the tree rebuilds on a move", async () => {
		qc.setQueryData(["folders", "42"], {
			folders: [
				{ id: "5", parent_id: null, name: "src", count: 3 },
				{ id: "9", parent_id: null, name: "dst", count: 1 },
			],
		});
		seedFolderNotesById("5", [{ id: "1" }, { id: "2" }, { id: "3" }]);
		seedFolderNotesById("9", [{ id: "4" }]);

		let resolvePost!: (v: unknown) => void;
		post.mockReturnValue(
			new Promise((r) => {
				resolvePost = r;
			}),
		);

		const { result } = renderHook(() => useBatchMoveNotes(), { wrapper });
		act(() => {
			result.current.mutate({ ids: ["1", "2"], target_folder: "dst" });
		});

		await waitFor(() => {
			const folders = qc.getQueryData<{ folders: Folder[] }>(["folders", "42"]);
			const byId = Object.fromEntries((folders?.folders ?? []).map((f) => [f.id, f.count]));
			expect(byId["5"]).toBe(1); // 3 source notes - 2 moved
			expect(byId["9"]).toBe(3); // 1 target note + 2 moved
		});

		resolvePost({ moved: 2 });
	});

	it("rolls back folder counts on server error", async () => {
		qc.setQueryData(["folders", "42"], {
			folders: [
				{ id: "5", parent_id: null, name: "src", count: 3 },
				{ id: "9", parent_id: null, name: "dst", count: 1 },
			],
		});
		seedFolderNotesById("5", [{ id: "1" }, { id: "2" }, { id: "3" }]);
		crdtCreateNote.mockRejectedValue(new CrdtOpError("create_failed", "crdt_create"));

		const { result } = renderHook(() => useBatchMoveNotes(), { wrapper });
		await act(async () => {
			try {
				await result.current.mutateAsync({
					ids: ["1", "2"],
					target_folder: "dst",
					paths: { "1": "src/1.md", "2": "src/2.md" },
				});
			} catch {
				// expected
			}
		});

		const folders = qc.getQueryData<{ folders: Folder[] }>(["folders", "42"]);
		const byId = Object.fromEntries((folders?.folders ?? []).map((f) => [f.id, f.count]));
		expect(byId["5"]).toBe(3);
		expect(byId["9"]).toBe(1);
	});

	it("moves notes to the vault root: appends to the by-id root list, strips the source", async () => {
		qc.setQueryData(["folders", "42"], {
			folders: [{ id: "5", parent_id: null, name: "src", count: 2 }],
		});
		seedFolderNotesById("5", [{ id: "1" }, { id: "2" }]);
		// Root shares the one id-keyed cache under the 'root' sentinel.
		qc.setQueryData(["folder-notes-by-id", "42", "root"], []);

		let resolvePost!: (v: unknown) => void;
		post.mockReturnValue(
			new Promise((r) => {
				resolvePost = r;
			}),
		);

		const { result } = renderHook(() => useBatchMoveNotes(), { wrapper });
		act(() => {
			result.current.mutate({ ids: ["1"], target_folder: "" });
		});

		await waitFor(() => {
			const root = qc.getQueryData<Array<{ id: string; folder: string }>>([
				"folder-notes-by-id",
				"42",
				"root",
			]);
			expect(root?.map((n) => n.id)).toContain("1");
			expect(root?.find((n) => n.id === "1")?.folder).toBe("");
			const src = qc.getQueryData<Array<{ id: string }>>(["folder-notes-by-id", "42", "5"]);
			expect(src?.map((n) => n.id)).toEqual(["2"]);
		});

		resolvePost({ moved: 1 });
	});

	it("moves a note FROM the root into a folder (strips the by-id root list)", async () => {
		qc.setQueryData(["folders", "42"], {
			folders: [{ id: "9", parent_id: null, name: "dst", count: 0 }],
		});
		qc.setQueryData(["folder-notes-by-id", "42", "9"], []);
		seedFolderNotesById("root", [{ id: "1", path: "a.md", folder: "" }]);

		let resolvePost!: (v: unknown) => void;
		post.mockReturnValue(
			new Promise((r) => {
				resolvePost = r;
			}),
		);

		const { result } = renderHook(() => useBatchMoveNotes(), { wrapper });
		act(() => {
			result.current.mutate({ ids: ["1"], target_folder: "dst" });
		});

		await waitFor(() => {
			const root = qc.getQueryData<Array<{ id: string }>>(["folder-notes-by-id", "42", "root"]);
			expect(root?.map((n) => n.id)).toEqual([]);
			const dst = qc.getQueryData<Array<{ id: string }>>(["folder-notes-by-id", "42", "9"]);
			expect(dst?.map((n) => n.id)).toContain("1");
		});

		resolvePost({ moved: 1 });
	});

	it("moves notes into a DERIVED folder (no marker) keyed under its syn: id", async () => {
		qc.setQueryData(["folders", "42"], {
			// A derived folder comes back from the backend with a null id; the
			// optimistic patch must key its note list under syn:<path>, the same id
			// the loader uses, and bump its count by name (id is null in this cache).
			folders: [
				{ id: "5", parent_id: null, name: "src", count: 2 },
				{ id: null, parent_id: null, name: "Derived", count: 0 },
			] as unknown as Folder[],
		});
		seedFolderNotesById("5", [{ id: "1" }, { id: "2" }]);
		qc.setQueryData(["folder-notes-by-id", "42", "syn:Derived"], []);

		let resolveMove: () => void = () => {};
		crdtCreateNote.mockReturnValue(
			new Promise((r) => {
				resolveMove = () => r("1");
			}),
		);

		const { result } = renderHook(() => useBatchMoveNotes(), { wrapper });
		act(() => {
			result.current.mutate({
				ids: ["1"],
				target_folder: "Derived",
				paths: { "1": "src/x.md" },
			});
		});

		await waitFor(() => {
			const dst = qc.getQueryData<Array<{ id: string; folder: string }>>([
				"folder-notes-by-id",
				"42",
				"syn:Derived",
			]);
			expect(dst?.map((n) => n.id)).toContain("1");
			expect(dst?.find((n) => n.id === "1")?.folder).toBe("Derived");
			const src = qc.getQueryData<Array<{ id: string }>>(["folder-notes-by-id", "42", "5"]);
			expect(src?.map((n) => n.id)).toEqual(["2"]);
			const folders = qc.getQueryData<{ folders: Folder[] }>(["folders", "42"]);
			expect(folders?.folders.find((f) => f.name === "Derived")?.count).toBe(1);
		});

		expect(crdtCreateNote).toHaveBeenCalledWith("1", "Derived/x.md");
		expect(post).not.toHaveBeenCalled();

		resolveMove();
	});

	it("decrements a DERIVED source folder count when moving notes OUT of it", async () => {
		// Source is a derived folder (null id in the raw cache, note list keyed
		// under its syn:<path> loader id). The decrement must match it by name.
		qc.setQueryData(["folders", "42"], {
			folders: [
				{ id: null, parent_id: null, name: "Derived", count: 2 },
				{ id: "9", parent_id: null, name: "dst", count: 0 },
			] as unknown as Folder[],
		});
		seedFolderNotesById("syn:Derived", [{ id: "1" }, { id: "2" }]);
		qc.setQueryData(["folder-notes-by-id", "42", "9"], []);

		let resolvePost!: (v: unknown) => void;
		post.mockReturnValue(
			new Promise((r) => {
				resolvePost = r;
			}),
		);

		const { result } = renderHook(() => useBatchMoveNotes(), { wrapper });
		act(() => {
			result.current.mutate({ ids: ["1"], target_folder: "dst" });
		});

		await waitFor(() => {
			const folders = qc.getQueryData<{ folders: Folder[] }>(["folders", "42"]);
			expect(folders?.folders.find((f) => f.name === "Derived")?.count).toBe(1);
			const src = qc.getQueryData<Array<{ id: string }>>([
				"folder-notes-by-id",
				"42",
				"syn:Derived",
			]);
			expect(src?.map((n) => n.id)).toEqual(["2"]);
		});

		resolvePost({ moved: 1 });
	});
});

describe("useBatchDeleteFolders", () => {
	it("POSTs ids with UUID idempotency header", async () => {
		post.mockResolvedValue({ deleted: 2 });

		const { result } = renderHook(() => useBatchDeleteFolders(), { wrapper });
		await act(async () => {
			await result.current.mutateAsync({ ids: ["7", "8"] });
		});

		expect(post).toHaveBeenCalledWith(
			"/folders/batch-delete",
			{ ids: ["7", "8"] },
			expect.objectContaining({
				headers: expect.objectContaining({
					"X-Idempotency-Key": expect.stringMatching(UUID_RE),
				}),
			}),
		);
	});

	it("optimistically removes target folders + descendants from the folders cache", async () => {
		qc.setQueryData(["folders", "42"], {
			folders: [
				{ id: "7", parent_id: null, name: "top", count: 0 },
				{ id: "8", parent_id: "7", name: "top/sub", count: 0 },
				{ id: "9", parent_id: null, name: "other", count: 0 },
			],
		});
		seedFolderNotesById("7", [{ id: "1" }]);
		seedFolderNotesById("8", [{ id: "2" }]);

		let resolvePost!: (v: unknown) => void;
		post.mockReturnValue(
			new Promise((r) => {
				resolvePost = r;
			}),
		);

		const { result } = renderHook(() => useBatchDeleteFolders(), { wrapper });
		act(() => {
			result.current.mutate({ ids: ["7"] });
		});

		await waitFor(() => {
			const folders = qc.getQueryData<{ folders: Folder[] }>(["folders", "42"]);
			expect(folders?.folders.map((f) => f.id).sort()).toEqual(["9"]);
		});

		// by-id lists for removed folder + descendant are dropped, sibling intact
		expect(qc.getQueryData(["folder-notes-by-id", "42", "7"])).toBeUndefined();
		expect(qc.getQueryData(["folder-notes-by-id", "42", "8"])).toBeUndefined();

		resolvePost({ deleted: 2 });
	});

	it("rolls back the folders cache when the server rejects", async () => {
		qc.setQueryData(["folders", "42"], {
			folders: [
				{ id: "7", parent_id: null, name: "top", count: 0 },
				{ id: "9", parent_id: null, name: "other", count: 0 },
			],
		});
		post.mockRejectedValue(new ApiError(500, "boom"));

		const { result } = renderHook(() => useBatchDeleteFolders(), { wrapper });
		await act(async () => {
			try {
				await result.current.mutateAsync({ ids: ["7"] });
			} catch {
				// expected
			}
		});

		const folders = qc.getQueryData<{ folders: Folder[] }>(["folders", "42"]);
		expect(folders?.folders.map((f) => f.id).sort()).toEqual(["7", "9"]);
	});
});

describe("useBatchMoveFolders", () => {
	it("POSTs target_parent (NOT target_folder) with UUID idempotency header", async () => {
		post.mockResolvedValue({ moved: 1 });

		const { result } = renderHook(() => useBatchMoveFolders(), { wrapper });
		await act(async () => {
			await result.current.mutateAsync({ ids: ["7"], target_parent: "dst" });
		});

		expect(post).toHaveBeenCalledWith(
			"/folders/batch-move",
			// Regression: the folders endpoint uses `target_parent`, NOT
			// `target_folder` (notes endpoint). Don't conflate them.
			{ ids: ["7"], target_parent: "dst" },
			expect.objectContaining({
				headers: expect.objectContaining({
					"X-Idempotency-Key": expect.stringMatching(UUID_RE),
				}),
			}),
		);
	});

	it("optimistically rewrites parent_id + name prefix for moved folder + descendants", async () => {
		qc.setQueryData(["folders", "42"], {
			folders: [
				{ id: "7", parent_id: null, name: "src", count: 0 },
				{ id: "8", parent_id: "7", name: "src/sub", count: 0 },
				{ id: "9", parent_id: null, name: "dst", count: 0 },
			],
		});

		let resolvePost!: (v: unknown) => void;
		post.mockReturnValue(
			new Promise((r) => {
				resolvePost = r;
			}),
		);

		const { result } = renderHook(() => useBatchMoveFolders(), { wrapper });
		act(() => {
			result.current.mutate({ ids: ["7"], target_parent: "dst" });
		});

		await waitFor(() => {
			const folders = qc.getQueryData<{ folders: Folder[] }>(["folders", "42"]);
			expect(folders?.folders.find((f) => f.id === "7")?.name).toBe("dst/src");
		});

		const folders = qc.getQueryData<{ folders: Folder[] }>(["folders", "42"]);
		// Moved folder's parent flips to the target.
		expect(folders?.folders.find((f) => f.id === "7")?.parent_id).toBe("9");
		// Descendant's path prefix is rewritten; parent_id is unchanged
		// (still points at id 7).
		expect(folders?.folders.find((f) => f.id === "8")?.name).toBe("dst/src/sub");
		expect(folders?.folders.find((f) => f.id === "8")?.parent_id).toBe("7");
		// Unrelated folder untouched.
		expect(folders?.folders.find((f) => f.id === "9")?.name).toBe("dst");

		resolvePost({ moved: 2 });
	});

	it("re-parents a folder under a DERIVED parent (syn: id)", async () => {
		qc.setQueryData(["folders", "42"], {
			// Derived parent: backend id is null. The moved folder's parent_id must
			// flip to syn:<path> (the loader id), and its name prefix to the path.
			folders: [
				{ id: "7", parent_id: null, name: "src", count: 0 },
				{ id: null, parent_id: null, name: "Derived", count: 0 },
			] as unknown as Folder[],
		});

		let resolvePost!: (v: unknown) => void;
		post.mockReturnValue(
			new Promise((r) => {
				resolvePost = r;
			}),
		);

		const { result } = renderHook(() => useBatchMoveFolders(), { wrapper });
		act(() => {
			result.current.mutate({ ids: ["7"], target_parent: "Derived" });
		});

		await waitFor(() => {
			const folders = qc.getQueryData<{ folders: Folder[] }>(["folders", "42"]);
			const moved = folders?.folders.find((f) => f.id === "7");
			expect(moved?.name).toBe("Derived/src");
			expect(moved?.parent_id).toBe("syn:Derived");
		});

		expect(post).toHaveBeenCalledWith(
			"/folders/batch-move",
			{ ids: ["7"], target_parent: "Derived" },
			expect.anything(),
		);

		resolvePost({ moved: 1 });
	});

	it("rolls back on error", async () => {
		qc.setQueryData(["folders", "42"], {
			folders: [
				{ id: "7", parent_id: null, name: "src", count: 0 },
				{ id: "8", parent_id: "7", name: "src/sub", count: 0 },
			],
		});
		post.mockRejectedValue(new ApiError(409, "conflict"));

		const { result } = renderHook(() => useBatchMoveFolders(), { wrapper });
		await act(async () => {
			try {
				await result.current.mutateAsync({ ids: ["7"], target_parent: "dst" });
			} catch {
				// expected
			}
		});

		const folders = qc.getQueryData<{ folders: Folder[] }>(["folders", "42"]);
		expect(folders?.folders.find((f) => f.id === "7")?.name).toBe("src");
		expect(folders?.folders.find((f) => f.id === "7")?.parent_id).toBeNull();
		expect(folders?.folders.find((f) => f.id === "8")?.name).toBe("src/sub");
	});
});

describe("useSearch", () => {
	it("forwards an abort signal so superseded searches are cancelled", async () => {
		post.mockResolvedValue({ results: [] });

		const { result } = renderHook(() => useSearch("alpha"), { wrapper });
		await waitFor(() => expect(result.current.isSuccess).toBe(true));

		expect(post).toHaveBeenCalledWith(
			"/search",
			{ query: "alpha", limit: 20 },
			{ signal: expect.any(AbortSignal) },
		);
	});

	it("keeps previous results visible while the next query is in flight", async () => {
		const firstResults = [{ id: "1", path: "a.md", title: "A" }];
		post.mockResolvedValueOnce({ results: firstResults });

		const { result, rerender } = renderHook(({ q }) => useSearch(q), {
			wrapper,
			initialProps: { q: "alpha" },
		});
		await waitFor(() => expect(result.current.data).toEqual(firstResults));

		// Second query never resolves during the assertion window — previous
		// results must remain rendered instead of flickering to empty.
		post.mockImplementationOnce(() => new Promise(() => {}));
		rerender({ q: "alpha beta" });

		expect(result.current.data).toEqual(firstResults);
		expect(result.current.isPlaceholderData).toBe(true);
	});

	it("posts type and date filters when provided", async () => {
		post.mockResolvedValue({ results: [] });

		renderHook(
			() =>
				useSearch("x", {
					type: "Playbook",
					createdAfter: "2026-01-01T00:00:00Z",
					createdBefore: "2026-06-01T00:00:00Z",
					updatedAfter: "2026-02-01T00:00:00Z",
					updatedBefore: "2026-07-01T00:00:00Z",
				}),
			{ wrapper },
		);

		await waitFor(() =>
			expect(post).toHaveBeenCalledWith(
				"/search",
				{
					query: "x",
					limit: 20,
					type: "Playbook",
					created_after: "2026-01-01T00:00:00Z",
					created_before: "2026-06-01T00:00:00Z",
					updated_after: "2026-02-01T00:00:00Z",
					updated_before: "2026-07-01T00:00:00Z",
				},
				{ signal: expect.any(AbortSignal) },
			),
		);
	});

	it("omits unset filters from the POST body", async () => {
		post.mockResolvedValue({ results: [] });

		renderHook(() => useSearch("x", { type: "Playbook" }), { wrapper });

		await waitFor(() =>
			expect(post).toHaveBeenCalledWith(
				"/search",
				{ query: "x", limit: 20, type: "Playbook" },
				{ signal: expect.any(AbortSignal) },
			),
		);
	});
});

describe("useAttachments", () => {
	it("fetches /attachments and returns the attachments array", async () => {
		get.mockResolvedValue({
			attachments: [
				{
					id: "a-1",
					path: "a.png",
					mime_type: "image/png",
					size_bytes: 10,
					mtime: 1,
					updated_at: "2026-06-10T00:00:00Z",
				},
			],
		});

		const { result } = renderHook(() => useAttachments(), { wrapper });
		await waitFor(() => expect(result.current.data).toBeDefined());

		expect(get).toHaveBeenCalledWith("/attachments");
		expect(result.current.data?.[0]?.path).toBe("a.png");
	});
});

describe("useRenameAttachment", () => {
	it("POSTs /attachments/rename with {old_path, new_path} and invalidates folders + attachments", async () => {
		post.mockResolvedValue({ renamed: true, old_path: "img/a.png", new_path: "img/b.png" });
		const invalidateSpy = vi.spyOn(qc, "invalidateQueries");

		const { result } = renderHook(() => useRenameAttachment(), { wrapper });
		await act(async () => {
			await result.current.mutateAsync({ old_path: "img/a.png", new_path: "img/b.png" });
		});

		expect(post).toHaveBeenCalledWith("/attachments/rename", {
			old_path: "img/a.png",
			new_path: "img/b.png",
		});
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["folders", "42"] });
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["folderNotes", "42"] });
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["attachments", "42"] });
	});

	it("surfaces 409 as ApiError", async () => {
		post.mockRejectedValue(new ApiError(409, "conflict"));

		const { result } = renderHook(() => useRenameAttachment(), { wrapper });
		await expect(
			result.current.mutateAsync({ old_path: "a.png", new_path: "b.png" }),
		).rejects.toMatchObject({ status: 409 });
	});
});

describe("useBatchMoveAttachments", () => {
	it("POSTs paths + target_folder with UUID X-Idempotency-Key header", async () => {
		post.mockResolvedValue({ moved: 2 });

		const { result } = renderHook(() => useBatchMoveAttachments(), { wrapper });
		await act(async () => {
			await result.current.mutateAsync({ paths: ["a.png", "b.png"], target_folder: "img" });
		});

		expect(post).toHaveBeenCalledWith(
			"/attachments/batch-move",
			{ paths: ["a.png", "b.png"], target_folder: "img" },
			expect.objectContaining({
				headers: expect.objectContaining({
					"X-Idempotency-Key": expect.stringMatching(UUID_RE),
				}),
			}),
		);
	});

	it("invalidates folders + attachments on success", async () => {
		post.mockResolvedValue({ moved: 1 });
		const invalidateSpy = vi.spyOn(qc, "invalidateQueries");

		const { result } = renderHook(() => useBatchMoveAttachments(), { wrapper });
		await act(async () => {
			await result.current.mutateAsync({ paths: ["a.png"], target_folder: "img" });
		});

		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["folders", "42"] });
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["attachments", "42"] });
	});
});

describe("useBatchDeleteAttachments", () => {
	it("POSTs paths with UUID X-Idempotency-Key header", async () => {
		post.mockResolvedValue({ deleted: 2 });

		const { result } = renderHook(() => useBatchDeleteAttachments(), { wrapper });
		await act(async () => {
			await result.current.mutateAsync({ paths: ["a.png", "b.png"] });
		});

		expect(post).toHaveBeenCalledWith(
			"/attachments/batch-delete",
			{ paths: ["a.png", "b.png"] },
			expect.objectContaining({
				headers: expect.objectContaining({
					"X-Idempotency-Key": expect.stringMatching(UUID_RE),
				}),
			}),
		);
	});

	it("invalidates folders + attachments on success", async () => {
		post.mockResolvedValue({ deleted: 2 });
		const invalidateSpy = vi.spyOn(qc, "invalidateQueries");

		const { result } = renderHook(() => useBatchDeleteAttachments(), { wrapper });
		await act(async () => {
			await result.current.mutateAsync({ paths: ["a.png", "b.png"] });
		});

		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["folders", "42"] });
		expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["attachments", "42"] });
	});
});

describe("useUploadAttachment", () => {
	function wrapper() {
		const qc = new QueryClient({
			defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
		});
		const Wrapper = ({ children }: { children: React.ReactNode }) => (
			<QueryClientProvider client={qc}>{children}</QueryClientProvider>
		);
		return { qc, Wrapper };
	}

	it("POSTs the upload payload and invalidates folders + folderNotes + attachments", async () => {
		post.mockResolvedValue({ attachment: { id: "a1", path: "pic.png" } });
		const { qc, Wrapper } = wrapper();
		const spy = vi.spyOn(qc, "invalidateQueries");
		const { result } = renderHook(() => useUploadAttachment(), { wrapper: Wrapper });

		await act(async () => {
			await result.current.mutateAsync({
				path: "pic.png",
				mime_type: "image/png",
				content_base64: "AAAA",
				mtime: 1_718_000_000,
			});
		});

		expect(post).toHaveBeenCalledWith("/attachments", {
			path: "pic.png",
			mime_type: "image/png",
			content_base64: "AAAA",
			mtime: 1_718_000_000,
		});
		expect(spy).toHaveBeenCalledWith({ queryKey: ["folders", "42"] });
		expect(spy).toHaveBeenCalledWith({ queryKey: ["folderNotes", "42"] });
		expect(spy).toHaveBeenCalledWith({ queryKey: ["attachments", "42"] });
	});
});
