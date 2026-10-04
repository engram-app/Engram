import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useParams } from "react-router";
import { toast } from "sonner";
import {
	type AttachmentSummary,
	type Folder,
	type NoteSummary,
	useAttachments,
	useBatchDeleteAttachments,
	useBatchDeleteFolders,
	useBatchDeleteNotes,
	useBatchMoveAttachments,
	useBatchMoveFolders,
	useBatchMoveNotes,
	useCreateFolder,
	useCreateNote,
	useDeleteFolder,
	useDuplicateNote,
	useFolders,
	useNote,
	useRenameAttachment,
	useRenameFolder,
	useRenameNote,
	useVaultNotes,
} from "../api/queries";
import { uuid7 } from "../crdt/uuid7";
import { useFolderTreeState } from "../layout/folder-tree-context";
import { copyToClipboard } from "../lib/clipboard";
import { noteName } from "../lib/note-name";
import { listContainer } from "../lib/ui-classes";
import { useFileDropUpload } from "./attachment-upload/provider";
import { FileDropTargetContext, folderRegion } from "./tree/file-drop-region";
import { TREE_ROW_HEIGHT, TREE_SLOT_HEIGHT } from "./tree/row-metrics";
import { isSyntheticFolderId, syntheticFolderPath } from "./tree/synthesize-folders";
import { TreeRowVirtualized } from "./tree/tree-row-virtualized";
import { parseItemId, ROOT_ID } from "./tree/types";
import { useEngramTree } from "./tree/use-engram-tree";
import { ActionDrawer } from "./tree-actions/action-drawer";
import { type ActionId, actionsFor, selectionActions } from "./tree-actions/action-list";
import { ContextMenu } from "./tree-actions/context-menu";
import { DeleteConfirm } from "./tree-actions/delete-confirm";
import { nextCopyName } from "./tree-actions/duplicate";
import { MoveDialog } from "./tree-actions/move-dialog";
import { renameBaseName } from "./tree-actions/rename-path";

// Row shapes that <DeleteConfirm> and <MoveDialog> accept.
type DeleteRow =
	| { kind: "file"; path: string }
	| { kind: "folder"; path: string; childCount: number };
type MoveRow = { kind: "file"; path: string } | { kind: "folder"; path: string };

// Module-level stable empty arrays — passing `folders ?? []` / `attachments ?? []`
// creates a new reference each render while the query is loading, which spins
// up an infinite re-render loop in useEngramTree's rebuildTree effect.
const EMPTY_FOLDERS: Folder[] = [];
const EMPTY_ATTACHMENTS: AttachmentSummary[] = [];
const EMPTY_NOTES: NoteSummary[] = [];

type DialogState =
	| { kind: "none" }
	| { kind: "delete"; nodes: DeleteRow[]; itemIds: string[] }
	| { kind: "move"; nodes: MoveRow[]; itemIds: string[] }
	// `selection` is set when the right-clicked row was part of a multi-selection:
	// the menu then acts on every selected row instead of `itemId` alone.
	| {
			kind: "context";
			itemId: string;
			position: { x: number; y: number };
			selection?: string[];
	  }
	| { kind: "drawer"; itemId: string };

export default function FolderTree() {
	const { data: folders, isLoading, isError } = useFolders();
	// Every note in the vault, in one array. These three hooks are all views of
	// the SAME `['vault-tree']` query, so this is one fetch and one observer set
	// — and the loader below can answer "what is in this folder" synchronously
	// instead of going and asking for it.
	const { data: notes = EMPTY_NOTES } = useVaultNotes();
	const { data: attachments = EMPTY_ATTACHMENTS } = useAttachments();
	const allFolders = folders ?? EMPTY_FOLDERS;
	const { sort, pendingFolderRename, requestFolderRename, clearFolderRename, registerCollapseAll } =
		useFolderTreeState();
	const params = useParams();
	const selectedNoteId = params.itemId ?? null;

	const scrollRef = useRef<HTMLDivElement | null>(null);
	const [dialog, setDialog] = useState<DialogState>({ kind: "none" });
	// Row to outline while its menu is up — the context menu on desktop, the
	// action drawer on touch.
	const menuOpenId = dialog.kind === "context" || dialog.kind === "drawer" ? dialog.itemId : null;

	const batchDeleteNotes = useBatchDeleteNotes();
	const batchMoveNotes = useBatchMoveNotes();
	const batchDeleteFolders = useBatchDeleteFolders();
	const batchMoveFolders = useBatchMoveFolders();
	const renameNote = useRenameNote();
	const renameFolder = useRenameFolder();
	const duplicateNote = useDuplicateNote();
	const createNote = useCreateNote();
	const createFolder = useCreateFolder();
	const deleteFolder = useDeleteFolder();
	const renameAttachment = useRenameAttachment();
	const batchMoveAttachments = useBatchMoveAttachments();
	const batchDeleteAttachments = useBatchDeleteAttachments();

	// Rename handler — TreeRow already wires HT's renaming state. HT calls
	// back with the new leaf-name; we rebuild the new full path from the
	// existing item path's folder + new leaf name.
	const onRenameCommit = (itemId: string, newName: string) => {
		const p = parseItemId(itemId);
		if (p.kind === "note") {
			const item = notes.find((n) => n.id === p.id);
			if (!item) {
				return;
			}
			// `mutate` (not `mutateAsync`): the mutation's own onError already
			// raises a specific toast, so awaiting only to re-toast a generic
			// "Rename failed" would show the user two of them.
			renameNote.mutate({
				id: item.id,
				old_path: item.path,
				new_path: renameBaseName(item.path, newName),
			});
		} else if (p.kind === "folder") {
			// `allFolders` (not `folders`) so derived folders resolve too — folder
			// rename posts old_path/new_path, which needs no backend id.
			const folder = allFolders.find((f) => f.id === p.id);
			if (!folder) {
				return;
			}
			const parts = folder.name.split("/");
			parts[parts.length - 1] = newName;
			renameFolder.mutate({ old_path: folder.name, new_path: parts.join("/") });
		} else if (p.kind === "attachment") {
			renameAttachment.mutate({ old_path: p.path, new_path: renameBaseName(p.path, newName) });
		}
	};

	// Drag-and-drop move — partition sources by kind, dispatch to the
	// matching batch hook. Drop target must be a folder or the vault root.
	// A CRDT move = crdt_create per id at its NEW path, which the mutation builds
	// from each note's CURRENT path. Resolve those here (from the by-id cache the
	// tree renders) BEFORE the optimistic onMutate re-paths the rows.
	const resolveNotePaths = (ids: string[]): Record<string, string> => {
		const all = notes;
		const out: Record<string, string> = {};
		for (const id of ids) {
			const p = all.find((n) => n.id === id)?.path;
			if (p !== undefined) {
				out[id] = p;
			}
		}
		return out;
	};

	const onMove = (sourceIds: string[], targetItemId: string) => {
		const target = parseItemId(targetItemId);
		if (target.kind !== "folder" && target.kind !== "root") {
			return;
		}
		const parsed = sourceIds.map(parseItemId);
		const noteIds = parsed.flatMap((p) => (p.kind === "note" ? [p.id] : []));
		// Real-marker folders move by id; derived ones have no id, so they take the
		// same path-based rename the Move dialog uses. Splitting them keeps drag
		// and the dialog capable of the same things.
		const folderIds = parsed.flatMap((p) =>
			p.kind === "folder" && !isSyntheticFolderId(p.id) ? [p.id] : [],
		);
		const derivedFolderPaths = parsed.flatMap((p) =>
			p.kind === "folder" && isSyntheticFolderId(p.id) ? [syntheticFolderPath(p.id)] : [],
		);
		const attachmentPaths = parsed.flatMap((p) => (p.kind === "attachment" ? [p.path] : []));
		// Destination PATH ('' = vault root). Resolved from the synthesized tree so
		// a derived folder (syn: id) yields its path — moves into it work by path.
		const destFolder =
			target.kind === "root" ? "" : (allFolders.find((f) => f.id === target.id)?.name ?? "");
		if (noteIds.length > 0) {
			batchMoveNotes.mutate({
				ids: noteIds,
				target_folder: destFolder,
				paths: resolveNotePaths(noteIds),
			});
		}
		if (folderIds.length > 0) {
			batchMoveFolders.mutate({ ids: folderIds, target_parent: destFolder });
		}
		for (const path of derivedFolderPaths) {
			const leaf = path.split("/").pop() ?? path;
			renameFolder.mutate({
				old_path: path,
				new_path: destFolder ? `${destFolder}/${leaf}` : leaf,
			});
		}
		if (attachmentPaths.length > 0) {
			batchMoveAttachments.mutate({ paths: attachmentPaths, target_folder: destFolder });
		}
	};

	const { tree, virtualizer, items } = useEngramTree({
		folders: allFolders,
		attachments,
		notes,
		sort,
		scrollParentRef: scrollRef,
		onRenameCommit,
		onMove,
	});

	// The toolbar's collapse button lives in a sibling component, so hand it the
	// tree's own collapse rather than mirroring expansion state up into context.
	// Root is re-expanded straight after: HT walks the expanded set to build its
	// item list, so an unexpanded root renders NOTHING — collapseAll alone would
	// blank the sidebar rather than collapse it.
	useEffect(() => {
		registerCollapseAll(() => {
			tree.collapseAll();
			tree.getRootItem().expand();
		});
		return () => registerCollapseAll(null);
	}, [registerCollapseAll, tree]);

	// Register the scroll container with BOTH the virtualizer (scrollRef) and
	// headless-tree, whose getContainerProps supplies the empty-space drop handler
	// (drops not on a row resolve to the vault root). Depends only on the stable
	// `tree` instance — avoids ref churn from the new-object-every-render props.
	const containerProps = tree.getContainerProps("Files");
	const setContainerEl = useCallback(
		(el: HTMLDivElement | null) => {
			scrollRef.current = el;
			tree.registerElement(el);
		},
		[tree],
	);

	// getContainerProps is typed Record<string, any>; name the two handlers we
	// chain so the calls below are checked rather than asserted.
	const containerDrag: {
		onDragOver?: (ev: React.DragEvent) => void;
		onDrop?: (ev: React.DragEvent) => void;
	} = containerProps;

	const [rootDragOver, setRootDragOver] = useState(false);
	// OS files: a file can only land in a FOLDER, so any row aims at its folder and
	// the tree outlines that folder and everything under it. Empty space aims at
	// the vault root. Rows handle their own drops (see tree-row's useRowFileDrop).
	const uploadFiles = useFileDropUpload();
	const [fileFolder, setFileFolder] = useState<string | null>(null);
	const isFileDrag = (e: React.DragEvent) =>
		Boolean(uploadFiles) && e.dataTransfer.types.includes("Files");
	const onContainerDragOver = (e: React.DragEvent) => {
		if (isFileDrag(e)) {
			e.preventDefault();
			e.dataTransfer.dropEffect = "copy";
			setFileFolder("");
			return;
		}
		containerDrag.onDragOver?.(e);
		setRootDragOver(true);
	};
	const onContainerDragLeave = (e: React.DragEvent) => {
		setRootDragOver(false);
		// Leaving for a child is not leaving: only a real exit clears the outline.
		if (!(e.relatedTarget instanceof Node && e.currentTarget.contains(e.relatedTarget))) {
			setFileFolder(null);
		}
	};
	const onContainerDrop = (e: React.DragEvent) => {
		setRootDragOver(false);
		if (isFileDrag(e)) {
			e.preventDefault();
			setFileFolder(null);
			uploadFiles?.(Array.from(e.dataTransfer.files), "").catch(() => undefined);
			return;
		}
		containerDrag.onDrop?.(e);
	};
	const fileDropTarget = useMemo(
		() => ({ folder: fileFolder, setFolder: setFileFolder }),
		[fileFolder],
	);
	// The outlined block: the target folder's row through its last descendant.
	const fileRegion =
		fileFolder === null
			? null
			: folderRegion(
					items.map((i) => i.getItemData().item),
					fileFolder,
				);

	// Auto-expand the chain leading to the active note so users can see
	// where they are after navigation. Mirrors the old recursive
	// `containsSelected` behaviour but driven by HT's expand API.
	//
	// Reads the note through `useNote` (reactive) rather than a one-off
	// `qc.getQueryData` snapshot: the note's own fetch can resolve after
	// `folders` does, and a snapshot read inside an effect keyed only on
	// `folders` would miss that later arrival, since nothing re-runs the
	// effect once `folders` itself stops changing. Gated to once per
	// `selectedNoteId` (the ref below) so a LATER unrelated update to
	// `activeNote` or `folders` (e.g. a background refetch from an unrelated
	// cross-tab edit) does not silently re-expand a folder the user has since
	// collapsed by hand.
	const { data: activeNote, isPlaceholderData: activeNoteIsStub } = useNote(selectedNoteId);
	const autoExpandedForNoteRef = useRef<string | null>(null);
	useEffect(() => {
		// `activeNote.id !== selectedNoteId` is the stale-note gate: useNote holds
		// the PREVIOUS note on screen while the next one loads (so the editor pane
		// doesn't blank on every click), so for one beat the routed id and the
		// loaded note disagree. Spending this effect's one shot per note on the
		// stale one would expand the folder you came FROM and latch the real one
		// out — the ref below never fires twice for the same id.
		// The placeholder gate is the same argument one step further out: the
		// vault-tree stub also satisfies the id check, but its folder comes from
		// a cache that can be stale (moved on another device, or an in-flight
		// move whose tree invalidation hasn't landed). Spending the one shot on
		// it expands the OLD folder and latches the real one out for good.
		if (
			selectedNoteId === null ||
			!folders ||
			activeNoteIsStub ||
			activeNote?.id !== selectedNoteId ||
			!activeNote.folder
		) {
			return;
		}
		if (autoExpandedForNoteRef.current === selectedNoteId) {
			return;
		}
		autoExpandedForNoteRef.current = selectedNoteId;
		const segments = activeNote.folder.split("/");
		for (let i = 1; i <= segments.length; i++) {
			const path = segments.slice(0, i).join("/");
			const folder = folders.find((f) => f.name === path);
			if (folder) {
				const instance = tree.getItemInstance(`f:${folder.id}`);
				if (instance && !instance.isExpanded()) {
					instance.expand();
				}
			}
		}
	}, [selectedNoteId, folders, activeNote, activeNoteIsStub, tree]);

	// A just-created folder opens straight in rename mode, so its placeholder
	// name is never kept by accident. Runs on every render until it lands: the
	// folder only reaches the tree after `['folders']` refetches and HT rebuilds,
	// and its row only exists once its ancestors are expanded.
	useEffect(() => {
		if (pendingFolderRename === null) {
			return;
		}
		const created = allFolders.find((f) => f.name === pendingFolderRename);
		if (!created) {
			return;
		}
		const segments = pendingFolderRename.split("/").slice(0, -1);
		for (let i = 1; i <= segments.length; i++) {
			const ancestor = allFolders.find((f) => f.name === segments.slice(0, i).join("/"));
			const inst = ancestor ? tree.getItemInstance(`f:${ancestor.id}`) : undefined;
			if (inst && !inst.isExpanded()) {
				inst.expand();
			}
		}
		const instance = tree.getItemInstance(`f:${created.id}`);
		if (!instance) {
			return;
		}
		instance.startRenaming();
		clearFolderRename();
	}, [pendingFolderRename, allFolders, tree, clearFolderRename]);

	// Resolve a single item id → the row shape DeleteConfirm / MoveDialog accept.
	function rowsFor(itemId: string, mode: "delete"): DeleteRow[];
	function rowsFor(itemId: string, mode: "move"): MoveRow[];
	function rowsFor(itemId: string, mode: "delete" | "move"): DeleteRow[] | MoveRow[] {
		const p = parseItemId(itemId);
		if (p.kind === "note") {
			const note = lookupNote(p.id);
			if (!note) {
				return [];
			}
			return mode === "delete"
				? [{ kind: "file", path: note.path }]
				: [{ kind: "file", path: note.path }];
		}
		if (p.kind === "folder") {
			// `allFolders`, not `folders`: the synthesized list is a superset that
			// also covers attachment-only dirs and missing ancestors. Looking these
			// up in the raw list returned [] and the dialog opened empty.
			const folder = allFolders.find((f) => f.id === p.id);
			if (!folder) {
				return [];
			}
			const direct = folder.count;
			const descendants = allFolders
				.filter((f) => f.name.startsWith(`${folder.name}/`))
				.reduce((sum, f) => sum + f.count, 0);
			return mode === "delete"
				? [{ kind: "folder", path: folder.name, childCount: direct + descendants }]
				: [{ kind: "folder", path: folder.name }];
		}
		if (p.kind === "attachment") {
			return [{ kind: "file", path: p.path }];
		}
		return [];
	}

	function lookupNote(id: string): { id: string; path: string; title?: string } | undefined {
		return notes.find((n) => n.id === id);
	}

	// Folder path a creation action targets: the right-clicked folder, or '' for
	// the vault root (empty-space right-click). Null when the item is neither.
	function targetFolderPath(itemId: string): string | null {
		const p = parseItemId(itemId);
		if (p.kind === "root") {
			return "";
		}
		if (p.kind === "folder") {
			return allFolders.find((f) => f.id === p.id)?.name ?? "";
		}
		return null;
	}

	function kindOf(itemId: string): "file" | "folder" | "attachment" | "root" {
		const p = parseItemId(itemId);
		if (p.kind === "root") {
			return "root";
		}
		if (p.kind === "folder") {
			return "folder";
		}
		if (p.kind === "attachment") {
			return "attachment";
		}
		return "file";
	}

	function titleForItem(itemId: string): string {
		const p = parseItemId(itemId);
		if (p.kind === "folder") {
			// allFolders: the synthesized superset, so an attachment-only dir gets
			// its real name in the drawer instead of a generic "Folder".
			const f = allFolders.find((x) => x.id === p.id);
			return f ? (f.name.split("/").pop() ?? f.name) : "Folder";
		}
		if (p.kind === "note") {
			const n = lookupNote(p.id);
			return n ? noteName(n.path) : "Note";
		}
		if (p.kind === "attachment") {
			return p.path.split("/").pop() ?? p.path;
		}
		return "Vault root";
	}

	function openDelete(itemIds: string[]) {
		const nodes = itemIds.flatMap((id) => rowsFor(id, "delete"));
		setDialog({ kind: "delete", nodes, itemIds });
	}

	function openMove(itemIds: string[]) {
		const nodes = itemIds.flatMap((id) => rowsFor(id, "move"));
		setDialog({ kind: "move", nodes, itemIds });
	}

	// Path of a row the tree still holds, or undefined once it is gone.
	function livePath(itemId: string): string | undefined {
		const p = parseItemId(itemId);
		if (p.kind === "note") {
			return lookupNote(p.id)?.path;
		}
		if (p.kind === "folder") {
			return allFolders.find((f) => f.id === p.id)?.name;
		}
		if (p.kind === "attachment") {
			return attachments.some((a) => a.path === p.path) ? p.path : undefined;
		}
		return undefined;
	}

	// What a bulk action should act on. Two things HT's raw selection gets wrong:
	// - it keeps ids after their rows are gone (deleted on another device, or
	//   inside a folder deleted from the single-row menu), and sending one to
	//   the server fails the whole batch;
	// - a range from a folder down past its own notes holds both, and acting on
	//   both pulled the notes out of the folder they were moving with, or
	//   deleted them twice. The folder already carries them.
	function actionableSelection(ids: string[]): string[] {
		const rows = ids.flatMap((id) => {
			const path = livePath(id);
			return path === undefined ? [] : [{ id, path }];
		});
		const folderPaths = rows.filter((r) => parseItemId(r.id).kind === "folder").map((r) => r.path);
		return rows
			.filter((r) => !folderPaths.some((f) => r.path.startsWith(`${f}/`)))
			.map((r) => r.id);
	}

	// Raw ids decide whether a right-click landed INSIDE the selection; the
	// actionable ones are what the menu acts on and counts. Only a real
	// multi-selection counts: HT selects whatever was clicked last, so one id is
	// just "the row you clicked".
	const rawSelectedIds = tree.getSelectedItems().map((i) => i.getId());
	const selectedIds = actionableSelection(rawSelectedIds);
	const multiSelect = rawSelectedIds.length > 1;

	function handleContextMenu(itemId: string, x: number, y: number) {
		// Obsidian's rule: right-clicking OUTSIDE the selection acts on that row
		// alone, so a bulk action can never hit rows the user isn't pointing at.
		const selection =
			selectedIds.length > 1 && rawSelectedIds.includes(itemId) ? selectedIds : undefined;
		setDialog({ kind: "context", itemId, position: { x, y }, selection });
	}

	function copyWikilinks(itemIds: string[]) {
		const links = itemIds.flatMap((id) => {
			const p = parseItemId(id);
			const note = p.kind === "note" ? lookupNote(p.id) : undefined;
			// Wikilinks resolve by filename in Obsidian, never by H1 title.
			return note ? [`[[${noteName(note.path) || note.path}]]`] : [];
		});
		if (links.length === 0) {
			return;
		}
		copyToClipboard(links.join("\n")).then((ok) =>
			ok
				? toast.success(links.length === 1 ? "Copied wikilink" : `Copied ${links.length} wikilinks`)
				: toast.error("Copy failed"),
		);
	}

	function handleSelectionPick(actionId: ActionId, itemIds: string[]) {
		if (actionId === "delete") {
			openDelete(itemIds);
		} else if (actionId === "move") {
			openMove(itemIds);
		} else if (actionId === "copy-wikilink") {
			copyWikilinks(itemIds);
		}
	}

	function handleLongPress(itemId: string) {
		setDialog({ kind: "drawer", itemId });
	}

	function handleActionPick(actionId: ActionId, itemId: string) {
		switch (actionId) {
			// Both target the RIGHT-CLICKED folder, not the toolbar's active one.
			// Resolved from `allFolders` (which includes synthetic folders) so
			// creating inside an attachment-only directory works by path.
			case "new-note": {
				const target = targetFolderPath(itemId);
				if (target === null) {
					break;
				}
				createNote.mutate({ folder: target, id: uuid7() });
				break;
			}
			case "new-folder": {
				const target = targetFolderPath(itemId);
				if (target === null) {
					break;
				}
				createFolder.mutate(
					{ parent: target },
					{ onSuccess: ({ folder }) => requestFolderRename(folder) },
				);
				break;
			}
			case "rename": {
				const instance = tree.getItemInstance(itemId);
				if (instance) {
					instance.startRenaming();
				}
				break;
			}
			case "delete":
				openDelete([itemId]);
				break;
			case "move":
				openMove([itemId]);
				break;
			case "duplicate": {
				const p = parseItemId(itemId);
				if (p.kind !== "note") {
					break;
				}
				const note = lookupNote(p.id);
				if (!note) {
					break;
				}
				// No reliable sibling-name set on hand — pass an empty Set and let
				// the backend reject if collision happens; the toast surfaces it.
				const new_path = nextCopyName(note.path, new Set<string>());
				// `mutate`, not `mutateAsync` — the hook's onError already toasts, and
				// it distinguishes a name collision from a general failure. Catching
				// here too put a second, vaguer toast on top of the useful one.
				duplicateNote.mutate(
					{ src_path: note.path, new_path },
					{ onSuccess: () => toast.success("Duplicated") },
				);
				break;
			}
			case "copy-wikilink":
				copyWikilinks([itemId]);
				break;
			default:
				break;
		}
	}

	function partition(itemIds: string[]): {
		noteIds: string[];
		folderIds: string[];
		derivedFolderPaths: string[];
		attachmentPaths: string[];
	} {
		const noteIds: string[] = [];
		const folderIds: string[] = [];
		const derivedFolderPaths: string[] = [];
		const attachmentPaths: string[] = [];
		for (const id of itemIds) {
			const p = parseItemId(id);
			if (p.kind === "note") {
				noteIds.push(p.id);
			} else if (p.kind === "folder") {
				// A derived folder has no backend id, so it can't ride the id-keyed
				// batch endpoints. It still has a path, and delete/move both have
				// path-based routes — so split it out rather than dropping it.
				if (isSyntheticFolderId(p.id)) {
					derivedFolderPaths.push(syntheticFolderPath(p.id));
				} else {
					folderIds.push(p.id);
				}
			} else if (p.kind === "attachment") {
				attachmentPaths.push(p.path);
			}
		}
		return { noteIds, folderIds, derivedFolderPaths, attachmentPaths };
	}

	function commitDelete() {
		if (dialog.kind !== "delete") {
			return;
		}
		const { noteIds, folderIds, derivedFolderPaths, attachmentPaths } = partition(dialog.itemIds);
		if (noteIds.length > 0) {
			batchDeleteNotes.mutate({ ids: noteIds });
		}
		if (folderIds.length > 0) {
			batchDeleteFolders.mutate({ ids: folderIds });
		}
		// No id to batch on — DELETE /folders/*path takes one folder at a time.
		for (const path of derivedFolderPaths) {
			deleteFolder.mutate({ path });
		}
		if (attachmentPaths.length > 0) {
			batchDeleteAttachments.mutate({ paths: attachmentPaths });
		}
		tree.setSelectedItems([]);
		setDialog({ kind: "none" });
	}

	function commitMove(targetFolderName: string) {
		if (dialog.kind !== "move") {
			return;
		}
		const { noteIds, folderIds, derivedFolderPaths, attachmentPaths } = partition(dialog.itemIds);
		// Everything moves by PATH (targetFolderName is the folder path, '' = root),
		// so a derived folder with no marker is a valid destination.
		if (noteIds.length > 0) {
			batchMoveNotes.mutate({
				ids: noteIds,
				target_folder: targetFolderName,
				paths: resolveNotePaths(noteIds),
			});
		}
		if (folderIds.length > 0) {
			batchMoveFolders.mutate({ ids: folderIds, target_parent: targetFolderName });
		}
		// Moving a folder is a rename into a new parent — and rename is path-based,
		// so it's the route a derived folder can actually take.
		for (const path of derivedFolderPaths) {
			const leaf = path.split("/").pop() ?? path;
			renameFolder.mutate({
				old_path: path,
				new_path: targetFolderName ? `${targetFolderName}/${leaf}` : leaf,
			});
		}
		if (attachmentPaths.length > 0) {
			batchMoveAttachments.mutate({ paths: attachmentPaths, target_folder: targetFolderName });
		}
		tree.setSelectedItems([]);
		setDialog({ kind: "none" });
	}

	// flex-1 on every no-rows branch: FilesPanel is a flex column and only the
	// tree grows. Without it these shrink to one line and pull FolderActions +
	// VaultSwitcher up under the header — on an empty vault, and as a jump on
	// every vault while it loads.
	if (isLoading) {
		return (
			<p data-testid="folder-tree-root" className="flex-1 px-3 py-2 text-muted-foreground text-xs">
				Loading…
			</p>
		);
	}
	if (isError) {
		return (
			<p data-testid="folder-tree-root" className="flex-1 px-3 py-2 text-destructive text-xs">
				Failed to load folders.
			</p>
		);
	}
	// Empty only when there are neither folders nor root-level notes. A vault
	// with root notes but no folders (e.g. a freshly created "Untitled" at root)
	// must still render the tree — the loader stitches rootNotes under ROOT.
	//
	// The empty state renders INSIDE the container rather than replacing it, so
	// an empty vault keeps the right-click "New note" / "New folder" menu and the
	// drop-to-root zone. Swapping the container out for bare text is how an empty
	// vault ended up with no way in but the toolbar button.
	const isEmpty =
		!folders || (allFolders.length === 0 && notes.length === 0 && attachments.length === 0);

	return (
		<>
			{/* biome-ignore lint/a11y/noNoninteractiveElementInteractions: drag-and-drop drop zone; native HTML5 DnD has no keyboard equivalent, keyboard users move folders via the action menu */}
			<nav
				{...containerProps}
				ref={setContainerEl}
				onContextMenu={(e) => {
					// Empty space only — rows stopPropagation, but a right-click can
					// also land on the container's padding or below the last row.
					e.preventDefault();
					setDialog({ kind: "context", itemId: ROOT_ID, position: { x: e.clientX, y: e.clientY } });
				}}
				onDragOver={onContainerDragOver}
				onDragLeave={onContainerDragLeave}
				onDrop={onContainerDrop}
				data-testid="folder-tree-root"
				data-file-drop
				// px-2 insets the rows from the sidebar edges — rows are w-full, so
				// without it the hover/selection chip runs edge to edge.
				className={`relative min-h-0 flex-1 overflow-auto ${listContainer} ${
					rootDragOver || fileFolder === "" ? "bg-primary/10 ring-1 ring-ring ring-inset" : ""
				}`}
			>
				{/* minHeight ensures blank, droppable space below the rows even for a
            short tree, so there's always a place to drop "to root". */}
				<FileDropTargetContext.Provider value={fileDropTarget}>
					<div
						style={{ height: virtualizer.getTotalSize(), minHeight: "100%", position: "relative" }}
					>
						{isEmpty ? (
							<p className="px-1 py-0.5 text-muted-foreground text-xs">No notes yet.</p>
						) : null}
						{/* One outline around the folder a dragged file would land in: its row
					    through its last descendant. Rows are fixed-height slots, so the
					    box is plain arithmetic. */}
						{fileRegion ? (
							<div
								aria-hidden
								data-testid="file-drop-region"
								className="pointer-events-none absolute inset-x-0 rounded bg-primary/10 ring-1 ring-ring"
								style={{
									top: fileRegion.start * TREE_SLOT_HEIGHT,
									height: (fileRegion.end - fileRegion.start) * TREE_SLOT_HEIGHT + TREE_ROW_HEIGHT,
								}}
							/>
						) : null}
						{virtualizer.getVirtualItems().map((v) => (
							<TreeRowVirtualized
								key={items[v.index]?.getId() ?? v.index}
								virtualItem={v}
								items={items}
								activeId={selectedNoteId}
								menuOpenId={menuOpenId}
								multiSelect={multiSelect}
								onContextMenu={handleContextMenu}
								onLongPress={handleLongPress}
							/>
						))}
					</div>
				</FileDropTargetContext.Provider>
			</nav>

			{dialog.kind === "delete" && (
				<DeleteConfirm
					nodes={dialog.nodes}
					onConfirm={commitDelete}
					onCancel={() => setDialog({ kind: "none" })}
				/>
			)}
			{dialog.kind === "move" && (
				<MoveDialog
					nodes={dialog.nodes}
					// Every folder is a valid target now that moves go by path — including
					// derived folders (notes inside, no marker).
					folders={allFolders.map((f) => ({ name: f.name }))}
					onPick={commitMove}
					onCancel={() => setDialog({ kind: "none" })}
				/>
			)}
			{dialog.kind === "context" && (
				<ContextMenu
					actions={
						dialog.selection
							? selectionActions(dialog.selection.map(kindOf).filter((k) => k !== "root"))
							: actionsFor({ kind: kindOf(dialog.itemId) })
					}
					position={dialog.position}
					onPick={(actionId) =>
						dialog.selection
							? handleSelectionPick(actionId, dialog.selection)
							: handleActionPick(actionId, dialog.itemId)
					}
					// The action itself may open another dialog (delete/move) that
					// shares this same state slot. Only clear it if it's still the
					// context menu, so we do not stomp on a freshly opened dialog.
					onClose={() => setDialog((prev) => (prev.kind === "context" ? { kind: "none" } : prev))}
				/>
			)}
			{dialog.kind === "drawer" && (
				<ActionDrawer
					title={titleForItem(dialog.itemId)}
					actions={actionsFor({ kind: kindOf(dialog.itemId) })}
					onPick={(actionId) => handleActionPick(actionId, dialog.itemId)}
					// Same reasoning as the context menu above.
					onClose={() => setDialog((prev) => (prev.kind === "drawer" ? { kind: "none" } : prev))}
				/>
			)}
		</>
	);
}
