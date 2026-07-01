import type { ItemInstance } from "@headless-tree/core";
import { ChevronRight, File, FileText, Image } from "lucide-react";
import type React from "react";
import { Link } from "react-router";
import { RenameInput } from "../tree-actions/rename-input";
import { useLongPress } from "../tree-actions/use-long-press";
import type { LoaderItem } from "./loader";
import { isSyntheticFolderId } from "./synthesize-folders";
import type { TreeItem } from "./types";

interface Props {
	instance: ItemInstance<LoaderItem>;
	onContextMenu?: (itemId: string, x: number, y: number) => void;
	onLongPress?: (itemId: string) => void;
	onFolderHover?: (folderId: string) => void;
}

export function TreeRow({ instance, onContextMenu, onLongPress, onFolderHover }: Props) {
	const itemId = instance.getId();
	const longPressHandlers = useLongPress({
		onLongPress: () => onLongPress?.(itemId),
	});
	const longPressProps = onLongPress ? longPressHandlers : undefined;
	const contextMenuHandler = onContextMenu
		? (e: React.MouseEvent) => {
				e.preventDefault();
				onContextMenu(itemId, e.clientX, e.clientY);
			}
		: undefined;

	const data = instance.getItemData();
	const item = data.item;
	const depth = instance.getItemMeta()?.level ?? 0;
	const folderPad = depth * 12 + 4;
	const notePad = folderPad + 20; // align note label under folder name (chevron 16px + gap 4px)

	if (instance.isRenaming()) {
		const tree = instance.getTree();
		return (
			<div
				className="flex items-center gap-1 py-0.5 pr-3 pl-1"
				style={{ paddingLeft: `${item.kind === "folder" ? folderPad : notePad}px` }}
			>
				<RenameInput
					initial={leafName(item)}
					kind={item.kind === "folder" ? "folder" : "file"}
					onCommit={(value) => {
						const treeWithRename = tree as unknown as {
							completeRenaming: () => void;
							getRenamingValue: () => string;
							applySubStateUpdate?: (k: "renamingValue", updater: () => string) => void;
							setState?: (
								updater: (s: { renamingValue?: string }) => { renamingValue?: string },
							) => void;
						};
						// RenameInput owns the input value; sync it onto HT renaming state before completing.
						// HT exposes renamingValue via state — bypass cleanly by writing through setState if present.
						treeWithRename.setState?.((s) => ({ ...s, renamingValue: value }));
						treeWithRename.completeRenaming();
					}}
					onCancel={() => tree.abortRenaming()}
				/>
			</div>
		);
	}

	if (item.kind === "folder") {
		// Synthetic folders are UI-only scaffolding for attachment-only dirs — they
		// have no backend record, so rename/delete/move and note-prefetch don't
		// apply. Drop their action affordances; expansion (to reveal the
		// attachments inside) still works.
		const isSynthetic = isSyntheticFolderId(item.id);
		const hoverPrefetch = onFolderHover && !isSynthetic ? () => onFolderHover(item.id) : undefined;
		return (
			<button
				type="button"
				{...instance.getProps()}
				{...(isSynthetic ? {} : longPressProps)}
				// getProps() spreads role="treeitem" from @headless-tree; declare it
				// explicitly so the linter sees the role that supports aria-expanded/selected
				role="treeitem"
				onContextMenu={isSynthetic ? undefined : contextMenuHandler}
				onPointerEnter={hoverPrefetch}
				onFocus={hoverPrefetch}
				aria-expanded={instance.isExpanded()}
				aria-selected={instance.isSelected()}
				className={rowClass(instance)}
				style={{ paddingLeft: `${folderPad}px` }}
			>
				<IndentGuides depth={depth} />
				<Chevron open={instance.isExpanded()} />
				<span className="min-w-0 flex-1 truncate">{item.name}</span>
			</button>
		);
	}

	if (item.kind === "attachment") {
		const filename = item.path.split("/").pop() ?? item.path;
		const dot = filename.lastIndexOf(".");
		const ext = dot > 0 ? filename.slice(dot + 1).toLowerCase() : null;
		const Icon = item.mime.startsWith("image/")
			? Image
			: item.mime === "application/pdf"
				? FileText
				: File;
		// Routed by uuid under the unified /note/:id (VaultItemPage resolves
		// note-vs-file) so the URL survives a rename/move. The HT itemId stays
		// path-keyed (internal tree machinery).
		return (
			<Link
				to={`/note/${item.id}`}
				{...instance.getProps()}
				{...longPressProps}
				onContextMenu={contextMenuHandler}
				aria-selected={instance.isSelected()}
				className={rowClass(instance)}
				style={{ paddingLeft: `${notePad}px` }}
			>
				<IndentGuides depth={depth} />
				<Icon
					aria-hidden="true"
					className="h-3.5 w-3.5 shrink-0 text-gray-400 dark:text-gray-500"
				/>
				<span className="min-w-0 flex-1 truncate">{filename}</span>
				{ext && (
					<span className="shrink-0 text-gray-400 text-xs dark:text-gray-500">
						{ext.toUpperCase()}
					</span>
				)}
			</Link>
		);
	}

	const htProps = instance.getProps();
	const handleNoteDragStart = (e: React.DragEvent) => {
		// Run HT's own drag init first (it tracks the drag via internal state).
		(htProps.onDragStart as ((ev: React.DragEvent) => void) | undefined)?.(e);
		// Then strip the <a href> link payload the browser auto-adds, so Chrome/Edge
		// don't offer a split view / "open in new tab" while dragging the note within
		// the tree. HT's move reads internal state, not dataTransfer, so this is safe.
		e.dataTransfer.clearData("text/uri-list");
		e.dataTransfer.clearData("text/plain");
		e.dataTransfer.clearData("text/html");
	};

	return (
		<Link
			to={`/note/${item.id}`}
			{...htProps}
			{...longPressProps}
			onContextMenu={contextMenuHandler}
			onDragStart={handleNoteDragStart}
			aria-selected={instance.isSelected()}
			className={rowClass(instance)}
			style={{ paddingLeft: `${notePad}px` }}
		>
			<IndentGuides depth={depth} />
			<span className="min-w-0 flex-1 truncate">{noteLabel(item)}</span>
			{item.ext && item.ext !== "md" && (
				<span className="shrink-0 text-gray-400 text-xs uppercase dark:text-gray-500">
					{item.ext}
				</span>
			)}
		</Link>
	);
}

function rowClass(instance: ItemInstance<LoaderItem>): string {
	// `isDragTarget` is provided by dragAndDropFeature; guard in case the row is
	// rendered without it (tests).
	const dragOver = (instance as { isDragTarget?: () => boolean }).isDragTarget?.() ?? false;
	return [
		// w-full so the folder <button> stretches like the note <a> (form controls
		// shrink to content by default) — gives both the same full-width hover hit.
		// relative anchors the absolutely-positioned indent guides.
		"relative flex w-full items-center gap-1 rounded py-0.5 pl-1 pr-3 text-left",
		instance.isSelected()
			? "bg-blue-50 dark:bg-blue-950 font-medium text-blue-700 dark:text-blue-300"
			: "text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-800",
		dragOver ? "ring-1 ring-inset ring-blue-400 bg-blue-100/60 dark:bg-blue-900/40" : "",
	].join(" ");
}

function leafName(item: TreeItem): string {
	if (item.kind === "folder") {
		return item.name;
	}
	return item.path.split("/").pop() ?? item.path;
}

function noteLabel(item: Extract<TreeItem, { kind: "note" }>): string {
	return item.title || item.path.split("/").pop() || item.path;
}

// Obsidian-style vertical indentation guides. A row at depth d draws one line
// per ancestor level, each in the 4px gutter just left of that level's chevron.
// Each line spans the full row height, so stacked rows form continuous lines
// down a folder's children without tracking where the folder ends.
const INDENT_STEP = 12;

// The guide spans for a given depth are static, so build them once per depth
// and reuse — every visible row re-renders on rebuild/hover/selection, and the
// elements are immutable.
const guideCache = new Map<number, React.ReactNode>();

function IndentGuides({ depth }: { depth: number }) {
	if (depth <= 0) {
		return null;
	}
	let guides = guideCache.get(depth);
	if (!guides) {
		guides = Array.from({ length: depth }, (_, i) => (
			<span
				key={i}
				aria-hidden="true"
				className="pointer-events-none absolute inset-y-0 w-px bg-gray-200 dark:bg-gray-700"
				style={{ left: `${(i + 1) * INDENT_STEP}px` }}
			/>
		));
		guideCache.set(depth, guides);
	}
	return <>{guides}</>;
}

function Chevron({ open }: { open: boolean }) {
	return (
		<ChevronRight
			aria-hidden="true"
			className={`h-4 w-4 shrink-0 text-gray-400 transition-transform dark:text-gray-500 ${
				open ? "rotate-90" : ""
			}`}
		/>
	);
}
