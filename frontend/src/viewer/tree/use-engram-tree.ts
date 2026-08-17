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
import type { QueryClient } from "@tanstack/react-query";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useEffect, useMemo, useRef } from "react";
import {
	type AttachmentSummary,
	type Folder,
	type NoteSummary,
	ROOT_FOLDER_ID,
} from "../../api/queries";
import { resolveDropMove } from "./drop-redirect";
import { buildLoader, type LoaderItem, type SortKey } from "./loader";
import { TREE_SLOT_HEIGHT } from "./row-metrics";
import { type ParsedItemId, parseItemId, ROOT_ID } from "./types";

interface Deps {
	folders: Folder[];
	attachments?: AttachmentSummary[];
	qc: QueryClient;
	vaultId: string;
	sort: SortKey;
	scrollParentRef: React.RefObject<HTMLDivElement | null>;
	onRenameCommit: (itemId: string, newName: string) => void;
	onMove: (sourceIds: string[], targetItemId: string) => void;
}

// Loader-side data: HT stores LoaderItem as the per-item `T`.
type Data = LoaderItem;

/**
 * Stable structural fingerprint that drives `rebuildTree()`. Includes each
 * folder's `count` AND `parent_id` (not just its id) so both kinds of move
 * rebuild the tree:
 *  - a note move bumps the source/target folder `count` (see useBatchMoveNotes),
 *  - a folder move reparents it, changing `parent_id`.
 * Without these, headless-tree keeps a stale per-folder child list after a move
 * until the user manually collapses/expands the folder.
 *
 * Note-list changes (including root notes, now keyed under ROOT_FOLDER_ID) are
 * covered separately by the QueryCache subscription below, so they don't need
 * to be fingerprinted here.
 */
function attachmentsFingerprint(attachments?: AttachmentSummary[]): string {
	if (!attachments || attachments.length === 0) {
		return "0";
	}
	// length + max(updated_at) is enough: the list is static per fetch, and any
	// add/remove changes one of the two.
	let max = "";
	for (const a of attachments) {
		if (a.updated_at > max) {
			max = a.updated_at;
		}
	}
	return `${attachments.length}:${max}`;
}

// Cheap content fingerprint for a `folder-notes-by-id` list. A reconnect-driven
// refetch (backfillStructural) hits EVERY loaded folder, whether or not
// anything actually changed, and each one is a fresh array from a fresh
// fetch — a reference check alone can't tell a no-op refetch from a real
// change. Comparing this fingerprint against the last-seen one (below) lets a
// no-op refetch skip the rebuild instead of redrawing the whole tree for
// nothing.
function noteListFingerprint(data: unknown): string {
	if (!Array.isArray(data)) {
		return "";
	}
	// id/version/path covers identity + content + rename; updated_at/created_at
	// are ALSO load-bearing even though they never gate identity — sortNotes
	// (loader.ts) orders "Modified"/"Created" views by them, and a fingerprint
	// blind to a timestamp-only change (e.g. a background write that bumps
	// updated_at without bumping version) would skip the rebuild and leave that
	// sort order stale.
	return (data as NoteSummary[])
		.map((n) => `${n.id}:${n.version}:${n.path}:${n.updated_at}:${n.created_at}`)
		.sort()
		.join("|");
}

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
				qc: deps.qc,
				vaultId: deps.vaultId,
				sort: deps.sort,
				attachments: deps.attachments,
				onChildrenLoaded: (folderId) => {
					const t = treeRef.current;
					if (!t) {
						return;
					}
					// Root notes hang off the ROOT_ID container, not an `f:<id>` marker.
					const itemId = folderId === ROOT_FOLDER_ID ? ROOT_ID : `f:${folderId}`;
					const inst = t.getItemInstance(itemId);
					// invalidateChildrenIds returns a promise but we don't need to await
					inst?.invalidateChildrenIds();
				},
			}),
		[deps.folders, deps.qc, deps.vaultId, deps.sort, deps.attachments],
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
			const destId = (target as { item?: ItemInstance<Data> }).item?.getId();
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
	// When our `useFolders` query lands after mount, the dataLoader returns new
	// ids but HT keeps its cached (empty) item list. Force a rebuild when the
	// data shape changes — keyed on stable structural fingerprints so we never
	// re-trigger from spurious identity churn (rebuildTree → setState → render
	// would otherwise spin into a max-update-depth loop).
	const structureKey = `${treeStructureKey(deps.folders, deps.sort)}#${attachmentsFingerprint(deps.attachments)}`;
	const lastKey = useRef("");
	useEffect(() => {
		if (lastKey.current === structureKey) {
			return;
		}
		lastKey.current = structureKey;
		tree.rebuildTree();
	}, [tree, structureKey]);

	// The structure key above only tracks the `folders` cache + root note ids, so
	// it's blind to per-folder note-list changes. Optimistic note ops (move,
	// delete, create, duplicate) mutate the `folder-notes-by-id` lists the loader
	// reads — without this, the tree wouldn't rebuild until a refetch or a manual
	// collapse/expand. Subscribe to those cache writes and rebuild (coalesced via
	// a microtask so a batch op that patches many lists triggers a single pass).
	useEffect(() => {
		const cache = deps.qc.getQueryCache();
		let scheduled = false;
		const schedule = () => {
			if (scheduled) {
				return;
			}
			scheduled = true;
			queueMicrotask(() => {
				scheduled = false;
				treeRef.current?.rebuildTree();
			});
		};
		// Per-folder last-seen fingerprint, scoped to this effect so it resets
		// cleanly on a vault switch instead of comparing across vaults.
		const lastFingerprint = new Map<string, string>();
		const unsubscribe = cache.subscribe((event) => {
			const key = event.query.queryKey;
			if (!Array.isArray(key) || key[0] !== "folder-notes-by-id" || key[1] !== deps.vaultId) {
				return;
			}
			// Data presence/content changes only — ignore fetch-status churn
			// (pending/error) that would rebuild for no structural reason.
			if (event.type === "added" || event.type === "removed") {
				schedule();
			} else if (event.type === "updated" && event.action.type === "success") {
				const keyStr = key.join(":");
				const fingerprint = noteListFingerprint(event.query.state.data);
				if (lastFingerprint.get(keyStr) === fingerprint) {
					// A backfill/reconnect refetch that landed the SAME notes — the
					// common case on a socket hiccup. Nothing to redraw.
					return;
				}
				lastFingerprint.set(keyStr, fingerprint);
				schedule();
			}
		});
		return unsubscribe;
	}, [deps.qc, deps.vaultId]);

	const items = tree.getItems();

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
