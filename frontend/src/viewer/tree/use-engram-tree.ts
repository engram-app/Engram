import {
	type DragTarget,
	dragAndDropFeature,
	expandAllFeature,
	hotkeysCoreFeature,
	type ItemInstance,
	renamingFeature,
	searchFeature,
	selectionFeature,
	syncDataLoaderFeature,
} from "@headless-tree/core";
import { useTree } from "@headless-tree/react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useEffect, useMemo, useRef } from "react";
import type { AttachmentSummary, Folder, NoteSummary } from "../../api/queries";
import { resolveDropMove } from "./drop-redirect";
import { buildLoader, type LoaderItem, type SortKey } from "./loader";
import { TREE_SLOT_HEIGHT } from "./row-metrics";
import { type ParsedItemId, parseItemId, ROOT_ID } from "./types";

interface Deps {
	folders: Folder[];
	attachments?: AttachmentSummary[];
	notes: NoteSummary[];
	sort: SortKey;
	scrollParentRef: React.RefObject<HTMLDivElement | null>;
	onRenameCommit: (itemId: string, newName: string) => void;
	onMove: (sourceIds: string[], targetItemId: string) => void;
}

// Loader-side data: HT stores LoaderItem as the per-item `T`.
type Data = LoaderItem;

/**
 * Rebuild is driven by REFERENCE identity of the three arrays the loader reads.
 *
 * They are all `select` views of the one `['vault-tree', vaultId]` entry, and
 * react-query keeps a select result referentially stable until the underlying
 * data actually changes — including across a refetch that returns the same
 * bytes, thanks to structural sharing. So "did anything change?" is `!==`.
 *
 * This replaced a hand-rolled content fingerprint (sorted id:version:path:
 * timestamps over every note) that existed only because the old per-folder
 * caches handed out a fresh array on every no-op refetch and identity told you
 * nothing.
 */

type TreeLoader = ReturnType<typeof buildLoader>;

/**
 * Stand-in row for an id whose data has not landed yet — the folders query is
 * refetching, or `inner` was just rebuilt (its `childIndex` starts empty), so
 * the id cannot be resolved for a tick even though the row is on screen.
 *
 * The kind is encoded in the id, so it is knowable with ZERO loaded data.
 * Deriving it is the whole point: this used to hardcode
 * `item.kind: "folder"` + `isFolder: false`, which is self-contradictory. The
 * render path switches on `item.kind` and drew a chevron, while headless-tree
 * switches on `isItemFolder` and saw a LEAF — and HT reads that at click time.
 * A click landing inside the window therefore took the leaf branch: it selected
 * the row and never toggled expansion. Nothing re-clicks, so the folder stayed
 * shut until the user clicked again (#1178, seen as a `move note propagates to
 * a second tab` e2e flake).
 *
 * `parseItemId` throws on a malformed id; this must stay total, because its
 * only job is to keep HT from crashing mid-render.
 */
function placeholderItem(itemId: string): Data {
	let parsed: ParsedItemId | null = null;
	try {
		parsed = parseItemId(itemId);
	} catch {
		// Unknown id shape. Fall through to the leaf placeholder below: a leaf is
		// the safe default for something we cannot name, since claiming it is a
		// folder would invite HT to ask for children that will never exist.
	}
	if (parsed?.kind === "folder") {
		return {
			itemId,
			item: { kind: "folder", id: parsed.id, path: "", name: itemId, count: 0 },
			isFolder: true,
		};
	}
	if (parsed?.kind === "attachment") {
		return {
			itemId,
			item: { kind: "attachment", id: itemId, path: parsed.path, mime: "", size: 0 },
			isFolder: false,
		};
	}
	return {
		itemId,
		item: {
			kind: "note",
			id: parsed?.kind === "note" ? parsed.id : itemId,
			path: "",
			title: itemId,
			ext: null,
		},
		isFolder: false,
	};
}

export function treeStructureKey(
	folders: Pick<Folder, "id" | "count" | "parent_id">[],
	sort: SortKey,
): string {
	const folderKey = folders.map((f) => `${f.id}:${f.count}:${f.parent_id ?? ""}`).join("|");
	return `${folderKey}::${sort}`;
}

export function useEngramTree(deps: Deps) {
	const treeRef = useRef<ReturnType<typeof useTree<Data>> | null>(null);
	const inner = useMemo(
		() =>
			buildLoader({
				folders: deps.folders,
				notes: deps.notes,
				sort: deps.sort,
				attachments: deps.attachments,
			}),
		[deps.folders, deps.notes, deps.sort, deps.attachments],
	);

	const dataLoader = useMemo(() => createTreeDataLoader(inner), [inner]);

	const tree = useTree<Data>({
		rootItemId: ROOT_ID,
		// Without expanding root, HT renders no items — its `getItems()` walks the
		// expanded set, and an unexpanded root means the top-level folders never
		// become visible. Seed expandedItems with the root id so its direct
		// children render on first mount.
		initialState: { expandedItems: [ROOT_ID] },
		dataLoader,
		getItemName: (item: ItemInstance<Data>) => {
			const d = item.getItemData();
			if (!d) {
				return "";
			}
			const t = d.item;
			if (t.kind === "folder") {
				return t.name;
			}
			if (t.kind === "attachment") {
				return t.path.split("/").pop() ?? t.path;
			}
			return t.title;
		},
		isItemFolder: (item: ItemInstance<Data>) => {
			const d = item.getItemData();
			return d?.isFolder ?? false;
		},
		// Reparent-only: drops go INTO the hovered folder (or, in empty space, to
		// root). canReorder:true would surface a between-items line whose target is
		// the row's PARENT — dropping on a top-level folder's edge would silently
		// land at root. We have no persisted order, so the destination-folder
		// highlight (isDragTarget) is the right affordance, not a reorder line.
		canReorder: false,
		onRename: (item: ItemInstance<Data>, value: string) => deps.onRenameCommit(item.getId(), value),
		onDrop: (dragged: ItemInstance<Data>[], target: DragTarget<Data>) => {
			// HT normalizes `target.item` to the destination container (the parent
			// folder for between-siblings, or the folder dropped onto). We ignore the
			// insertion index and reparent into it. See drop-redirect.ts.
			const destId = "item" in target ? target.item?.getId() : undefined;
			const sources = dragged.map((i) => ({
				id: i.getId(),
				parentId: i.getParent()?.getId(),
			}));
			const move = resolveDropMove(sources, destId);
			if (move) {
				deps.onMove(move.ids, move.dest);
			}
		},
		features: [
			syncDataLoaderFeature,
			selectionFeature,
			hotkeysCoreFeature,
			dragAndDropFeature,
			renamingFeature,
			searchFeature,
			expandAllFeature,
		],
	});

	treeRef.current = tree;

	// HT only computes its flat-item list on mount + on expandedItems change.
	// When new data lands, the dataLoader returns new ids but HT keeps its
	// cached item list, so force a rebuild. `inner` changes identity exactly
	// when one of the loader's inputs did.
	useEffect(() => {
		treeRef.current?.rebuildTree();
	}, []);
	const lastInner = useRef(inner);
	useEffect(() => {
		if (lastInner.current === inner) {
			return;
		}
		lastInner.current = inner;
		tree.rebuildTree();
	}, [tree, inner]);

	const items = tree.getItems();

	// biome-ignore lint/nursery/useReactCompiler: useVirtualizer's internals, not ours. Nothing in this file can satisfy the rule short of dropping @tanstack/react-virtual.
	const virtualizer = useVirtualizer({
		count: items.length,
		getScrollElement: () => deps.scrollParentRef.current,
		// Exact, not an estimate: rows are pinned to the same constant, so no
		// measurement pass is needed. See row-metrics.ts for why we don't measure.
		estimateSize: () => TREE_SLOT_HEIGHT,
		overscan: 8,
	});

	return { tree, virtualizer, items };
}

// Bridge our LoaderItem-returning loader to HT's TreeDataLoader<T> shape
// (getItem -> T, getChildren -> string[]). We index getChildren results
// by itemId so a subsequent getItem(id) lookup hits the same row data.
export function createTreeDataLoader(inner: Pick<TreeLoader, "getItem" | "getChildren">) {
	const childIndex = new Map<string, LoaderItem>();
	return {
		getItem(itemId: string): Data {
			if (itemId === ROOT_ID) {
				return {
					itemId: ROOT_ID,
					item: { kind: "folder", id: "root", path: "", name: "", count: 0 },
					isFolder: true,
				};
			}
			const cached = childIndex.get(itemId);
			if (cached) {
				return cached;
			}
			const direct = inner.getItem(itemId);
			if (direct) {
				childIndex.set(itemId, direct);
				return direct;
			}
			return placeholderItem(itemId);
		},
		getChildren(itemId: string): string[] {
			const kids = inner.getChildren(itemId);
			for (const k of kids) {
				childIndex.set(k.itemId, k);
			}
			return kids.map((k) => k.itemId);
		},
	};
}
