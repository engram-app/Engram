import type { ItemInstance } from "@headless-tree/core";
import { ChevronRight, File, FileText, Image } from "lucide-react";
import type React from "react";
import { Link } from "react-router";
import { noteName } from "../../lib/note-name";
import { RenameInput } from "../tree-actions/rename-input";
import { useLongPress } from "../tree-actions/use-long-press";
import type { LoaderItem } from "./loader";
import { TREE_ROW_HEIGHT } from "./row-metrics";
import { isSyntheticFolderId } from "./synthesize-folders";
import type { TreeItem } from "./types";

interface Props {
	instance: ItemInstance<LoaderItem>;
	// Id of the file currently open in the editor (the route param). The
	// highlight is pinned to THIS, not to headless-tree's selection: HT selects
	// whatever was clicked last, so expanding a folder would steal the chip away
	// from the file you're actually looking at.
	activeId?: string | null;
	onContextMenu?: (itemId: string, x: number, y: number) => void;
	onLongPress?: (itemId: string) => void;
	onFolderHover?: (folderId: string) => void;
}

function rowClass(instance: ItemInstance<LoaderItem>, active: boolean): string {
	// `isDragTarget` is provided by dragAndDropFeature; guard in case the row is
	// rendered without it (tests).
	const dragOver = (instance as { isDragTarget?: () => boolean }).isDragTarget?.() ?? false;
	return [
		// w-full so the folder <button> stretches like the note <a> (form controls
		// shrink to content by default) — gives both the same full-width hover hit.
		// relative anchors the absolutely-positioned indent guides.
		"relative flex w-full items-center gap-1 rounded pl-1 pr-3 text-left",
		// A solid neutral chip, not a tint of the cyan primary — a tinted
		// highlight reads as "blue on blue" against this palette. Hover owns
		// `accent`, so the two states stay clearly distinct.
		active
			? "bg-tree-selected font-medium text-tree-selected-foreground"
			: "text-foreground hover:bg-accent hover:text-accent-foreground",
		dragOver ? "bg-primary/15 ring-1 ring-ring ring-inset" : "",
	].join(" ");
}

// What the rename box is seeded with. Rows already display files without their
// extension (it's rendered separately as a badge), so the box matches the row —
// and the extension stays out of the user's hands. `noteName` handles the base
// name for notes and attachments alike; folders have no extension to strip.
function renameSeed(item: TreeItem): string {
	return item.kind === "folder" ? item.name : noteName(item.path);
}

function noteLabel(item: Extract<TreeItem, { kind: "note" }>): string {
	return item.title || item.path.split("/").pop() || item.path;
}

// Obsidian-style vertical indentation guides. A row at depth d draws one line
// per ancestor level, each in the 4px gutter just left of that level's chevron.
// Each line spans its full SLOT (row height plus the gutter above and below),
// so stacked rows form continuous lines down a folder's children without
// tracking where the folder ends.
const INDENT_STEP = 12;

// A level-L guide should sit on the CENTRE of that ancestor's chevron, which
// measures at `L * INDENT_STEP + INDENT_STEP` from the row's left edge. `left`
// positions the span's left EDGE though, so without this the 1px line's centre
// lands half a pixel right of the chevron at every level — a constant offset,
// but one the eye reads as a growing drift once several guides stack up.
const GUIDE_WIDTH = 1;

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
		guides = Array.from({ length: depth }, (_, i) => i).map((level) => (
			<span
				key={`indent-${level}`}
				aria-hidden="true"
				// -inset-y-px, not inset-y-0: the row is TREE_ROW_HEIGHT inside a taller
				// slot, so a guide bounded by the row would break at every gutter.
				// Overshooting by the gutter's 1px each way makes the lines continuous.
				className="pointer-events-none absolute -inset-y-px w-px bg-border"
				style={{ left: `${(level + 1) * INDENT_STEP - GUIDE_WIDTH / 2}px` }}
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
			className={`h-4 w-4 shrink-0 text-muted-foreground transition-transform ${
				open ? "rotate-90" : ""
			}`}
		/>
	);
}

export function TreeRow({ instance, activeId, onContextMenu, onLongPress, onFolderHover }: Props) {
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
	const { item } = data;
	// Folders are never the "open" thing — only notes and attachments route to
	// /note/:id — so expanding one can't move the highlight.
	const active = item.kind !== "folder" && item.id === activeId;
	const depth = instance.getItemMeta()?.level ?? 0;
	const folderPad = depth * 12 + 4;
	const notePad = folderPad + 20; // align note label under folder name (chevron 16px + gap 4px)

	if (instance.isRenaming()) {
		const tree = instance.getTree();
		return (
			<div
				className="flex items-center gap-1 pr-3 pl-1"
				style={{
					paddingLeft: `${item.kind === "folder" ? folderPad : notePad}px`,
					height: TREE_ROW_HEIGHT,
				}}
			>
				<RenameInput
					initial={renameSeed(item)}
					kind={item.kind === "folder" ? "folder" : "file"}
					// RenameInput owns the input value directly, so HT's own
					// renamingValue state (normally fed by
					// getRenameInputProps().onChange) never sees these keystrokes.
					// HT's hotkeys-core feature listens for Enter on the tree
					// container in the native bubble phase, which fires before
					// this input's React onKeyDown (React's delegated listener
					// sits higher up the DOM and runs later in the same bubble).
					// That means HT's own completeRenaming hotkey can win the
					// race and commit with a stale renamingValue before onCommit
					// below ever runs. Sync on every keystroke, not only at
					// commit, so whichever path completes the rename first reads
					// the current typed value.
					onChange={(value) => tree.applySubStateUpdate("renamingValue", value)}
					onCommit={(value) => {
						tree.applySubStateUpdate("renamingValue", value);
						tree.completeRenaming();
					}}
					onCancel={() => tree.abortRenaming()}
				/>
			</div>
		);
	}

	if (item.kind === "folder") {
		// A synthetic folder has no backend record, so note-prefetch (id-keyed)
		// can't run for it. The MENU still opens: `actionsFor` narrows it to the
		// path-keyed creation actions. Suppressing the handler entirely just
		// handed the user the browser's own context menu.
		const isSynthetic = isSyntheticFolderId(item.id);
		const hoverPrefetch = onFolderHover && !isSynthetic ? () => onFolderHover(item.id) : undefined;
		return (
			<button
				type="button"
				{...instance.getProps()}
				{...longPressProps}
				// getProps() spreads role="treeitem" from @headless-tree; declare it
				// explicitly so the linter sees the role that supports aria-expanded/selected
				role="treeitem"
				onContextMenu={contextMenuHandler}
				onPointerEnter={hoverPrefetch}
				onFocus={hoverPrefetch}
				aria-expanded={instance.isExpanded()}
				aria-selected={instance.isSelected()}
				className={rowClass(instance, active)}
				style={{ paddingLeft: `${folderPad}px`, height: TREE_ROW_HEIGHT }}
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
				aria-current={active ? "page" : undefined}
				className={rowClass(instance, active)}
				style={{ paddingLeft: `${notePad}px`, height: TREE_ROW_HEIGHT }}
			>
				<IndentGuides depth={depth} />
				{/* On the active chip, inherit its text colour — `muted-foreground`
				    against a near-black background is unreadable. */}
				<Icon
					aria-hidden="true"
					className={`h-3.5 w-3.5 shrink-0 ${active ? "opacity-75" : "text-muted-foreground"}`}
				/>
				{/* Base name only — the badge beside it already carries the type,
				    and this keeps the row consistent with note rows and with what
				    the rename box seeds. */}
				<span className="min-w-0 flex-1 truncate">{noteName(item.path)}</span>
				{ext ? (
					<span className={`shrink-0 text-xs ${active ? "opacity-75" : "text-muted-foreground"}`}>
						{ext.toUpperCase()}
					</span>
				) : null}
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
			aria-current={active ? "page" : undefined}
			className={rowClass(instance, active)}
			style={{ paddingLeft: `${notePad}px`, height: TREE_ROW_HEIGHT }}
		>
			<IndentGuides depth={depth} />
			<span className="min-w-0 flex-1 truncate">{noteLabel(item)}</span>
			{item.ext && item.ext !== "md" && (
				<span
					className={`shrink-0 text-xs uppercase ${active ? "opacity-75" : "text-muted-foreground"}`}
				>
					{item.ext}
				</span>
			)}
		</Link>
	);
}
