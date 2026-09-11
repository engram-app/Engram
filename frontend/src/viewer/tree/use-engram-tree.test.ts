import { renderHook, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { Folder, NoteSummary } from "../../api/queries";
import { formatItemId } from "./types";
import { createTreeDataLoader, useEngramTree } from "./use-engram-tree";

// No client mock needed: the loader is a pure function of the arrays it is
// handed, so nothing here can reach the network.

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

const note = (id: string, path: string): NoteSummary => ({
	id,
	path,
	title: path,
	folder: path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "",
	tags: [],
	version: 1,
	mtime: "",
	created_at: "",
	updated_at: "",
});

describe("useEngramTree", () => {
	const folders: Folder[] = [{ id: "1", parent_id: null, name: "Projects", count: 1 }];
	const scrollRef = { current: null as HTMLDivElement | null };
	const baseDeps = {
		folders,
		notes: [] as NoteSummary[],
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

	// Rebuild is driven by reference identity of the loader's inputs, which are
	// `select` views of the one vault-tree query. A note op replaces the notes
	// array, so the tree redraws without anything having to fingerprint it.
	it("rebuilds when the notes array changes", async () => {
		const { result, rerender } = renderHook((props: typeof baseDeps) => useEngramTree(props), {
			initialProps: baseDeps,
		});
		const spy = vi.spyOn(result.current.tree, "rebuildTree");

		rerender({ ...baseDeps, notes: [note("n1", "Projects/n1.md")] });

		await waitFor(() => expect(spy).toHaveBeenCalled());
	});

	// The no-op case: a reconnect-driven refetch that lands identical bytes.
	// react-query's structural sharing hands back the SAME array, so identity
	// alone is enough to skip the redraw — this is what the old hand-rolled
	// content fingerprint over every note existed to decide.
	it("does not rebuild when the same arrays come back", async () => {
		const notes = [note("n1", "Projects/n1.md")];
		const props = { ...baseDeps, notes };
		const { result, rerender } = renderHook((p: typeof baseDeps) => useEngramTree(p), {
			initialProps: props,
		});
		const spy = vi.spyOn(result.current.tree, "rebuildTree");

		rerender({ ...props });
		await new Promise((r) => setTimeout(r, 0));
		expect(spy).not.toHaveBeenCalled();

		// A genuine change still rebuilds.
		rerender({ ...baseDeps, notes: [...notes, note("n2", "Projects/n2.md")] });
		await waitFor(() => expect(spy).toHaveBeenCalledTimes(1));
	});
});
