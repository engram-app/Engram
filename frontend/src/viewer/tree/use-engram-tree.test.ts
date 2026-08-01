import { QueryClient } from "@tanstack/react-query";
import { act, renderHook, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { Folder, NoteSummary } from "../../api/queries";
import { formatItemId } from "./types";
import { createTreeDataLoader, treeStructureKey, useEngramTree } from "./use-engram-tree";

describe("createTreeDataLoader", () => {
	// An `inner` that knows nothing — models the window where the folders query
	// has been re-keyed or is refetching, so `deps.folders` cannot resolve an id
	// the tree is still displaying.
	const emptyInner = { getItem: () => undefined, getChildren: () => [] };

	// #1178. The placeholder used to hardcode `isFolder: false`, which made a
	// folder row briefly claim to be a LEAF. headless-tree reads `isItemFolder`
	// at click time, so a click landing in that window took the leaf branch: it
	// selected the row and never toggled expansion, and since nothing re-clicks,
	// the folder stayed shut forever. Folder-ness is encoded in the item id, so
	// it is knowable with zero loaded data and must never be guessed.
	it("reports a folder as a folder even when its data has not landed", () => {
		const loader = createTreeDataLoader(emptyInner);
		const item = loader.getItem(formatItemId({ kind: "folder", id: "f-source" }));
		expect(item.isFolder).toBe(true);
	});

	it("keeps the placeholder's rendered kind consistent with isFolder", () => {
		const loader = createTreeDataLoader(emptyInner);
		const item = loader.getItem(formatItemId({ kind: "folder", id: "f-source" }));
		// The render path switches on `item.kind`; HT switches on `isFolder`. If
		// these disagree the row draws a chevron it will not honour.
		expect(item.item.kind === "folder").toBe(item.isFolder);
	});

	it("does not turn an unresolved note into a folder", () => {
		const loader = createTreeDataLoader(emptyInner);
		const item = loader.getItem(formatItemId({ kind: "note", id: "n1" }));
		expect(item.isFolder).toBe(false);
		expect(item.item.kind === "folder").toBe(false);
	});

	it("prefers real data over the placeholder once it lands", () => {
		const id = formatItemId({ kind: "folder", id: "f-real" });
		const real = {
			itemId: id,
			item: { kind: "folder" as const, id: "f-real", path: "Real", name: "Real", count: 0 },
			isFolder: true,
		};
		const loader = createTreeDataLoader({ getItem: () => real, getChildren: () => [] });
		expect(loader.getItem(id)).toBe(real);
	});
});

describe("treeStructureKey", () => {
	it("changes when a folder count changes (so a move rebuilds the tree)", () => {
		const before = treeStructureKey([{ id: "f1", count: 0, parent_id: null }], "name-asc");
		const after = treeStructureKey([{ id: "f1", count: 1, parent_id: null }], "name-asc");
		expect(after).not.toBe(before);
	});

	it("changes when a folder is reparented (folder move rebuilds the tree)", () => {
		const before = treeStructureKey([{ id: "f1", count: 0, parent_id: null }], "name-asc");
		const after = treeStructureKey([{ id: "f1", count: 0, parent_id: "p2" }], "name-asc");
		expect(after).not.toBe(before);
	});

	// Root-note changes no longer flow through the structure key — they live in
	// the id-keyed cache under 'root' and rebuild via the QueryCache subscription
	// (see the 'rebuilds … by-id list changes' test below).

	it("is stable when nothing structural changes", () => {
		expect(treeStructureKey([{ id: "f1", count: 2, parent_id: null }], "name-asc")).toBe(
			treeStructureKey([{ id: "f1", count: 2, parent_id: null }], "name-asc"),
		);
	});
});

describe("useEngramTree", () => {
	const folders: Folder[] = [{ id: "1", parent_id: null, name: "Projects", count: 1 }];
	const scrollRef = { current: null as HTMLDivElement | null };
	const baseDeps = {
		folders,
		qc: new QueryClient(),
		vaultId: "v",
		sort: "name-asc" as const,
		scrollParentRef: scrollRef,
		onRenameCommit: vi.fn(),
		onMove: vi.fn(),
	};

	it("returns a tree object + virtualizer", () => {
		const { result } = renderHook(() => useEngramTree(baseDeps));
		expect(result.current.tree).toBeDefined();
		expect(result.current.virtualizer).toBeDefined();
		expect(Array.isArray(result.current.items)).toBe(true);
	});

	it("rebuilds the tree when a folder-notes-by-id list changes", async () => {
		const qc = new QueryClient();
		const { result } = renderHook(() => useEngramTree({ ...baseDeps, qc }));
		const spy = vi.spyOn(result.current.tree, "rebuildTree");

		// A note op (move/delete/create) mutates a by-id list. The tree must
		// rebuild from that change alone — its folder structure key is unchanged.
		act(() => {
			qc.setQueryData(
				["folder-notes-by-id", "v", "1"],
				[
					{
						id: "n1",
						path: "Projects/n1.md",
						title: "n1",
						folder: "Projects",
						tags: [],
						version: 1,
						mtime: "",
						created_at: "",
						updated_at: "",
					},
				],
			);
		});

		await waitFor(() => expect(spy).toHaveBeenCalled());
	});

	it('rebuilds the tree when the root note list (by-id "root") changes', async () => {
		const qc = new QueryClient();
		const { result } = renderHook(() => useEngramTree({ ...baseDeps, qc }));
		const spy = vi.spyOn(result.current.tree, "rebuildTree");

		// Root notes now live in the same id-keyed cache under the 'root' sentinel.
		const note: NoteSummary = {
			id: "r1",
			path: "r1.md",
			title: "r1",
			folder: "",
			tags: [],
			version: 1,
			mtime: "",
			created_at: "",
			updated_at: "",
		};
		act(() => {
			qc.setQueryData(["folder-notes-by-id", "v", "root"], [note]);
		});

		await waitFor(() => expect(spy).toHaveBeenCalled());
	});
});
