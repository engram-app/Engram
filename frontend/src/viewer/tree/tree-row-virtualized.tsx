import type { ItemInstance } from "@headless-tree/core";
import type { VirtualItem } from "@tanstack/react-virtual";
import type { LoaderItem } from "./loader";
import { TREE_SLOT_HEIGHT } from "./row-metrics";
import { TreeRow } from "./tree-row";

interface Props {
	virtualItem: VirtualItem;
	items: ItemInstance<LoaderItem>[];
	instanceFor?: (itemId: string) => ItemInstance<LoaderItem> | undefined;
	activeId?: string | null;
	menuOpenId?: string | null;
	onContextMenu?: (itemId: string, x: number, y: number) => void;
	onLongPress?: (itemId: string) => void;
	onFolderHover?: (folderId: string) => void;
	onNoteHover?: (noteId: string) => void;
}

export function TreeRowVirtualized({
	virtualItem,
	items,
	instanceFor,
	activeId,
	menuOpenId,
	onContextMenu,
	onLongPress,
	onFolderHover,
	onNoteHover,
}: Props) {
	const fallback = items[virtualItem.index];
	if (!fallback) {
		return null;
	}
	const instance = instanceFor ? (instanceFor(fallback.getId()) ?? fallback) : fallback;

	return (
		<div
			// py-px splits the slot's gutter above and below the row, so neighbouring
			// hover/selection fills never touch. TreeRow pins itself to
			// TREE_ROW_HEIGHT, so row + gutter is exactly TREE_SLOT_HEIGHT.
			className="py-px"
			style={{
				position: "absolute",
				top: 0,
				left: 0,
				width: "100%",
				height: TREE_SLOT_HEIGHT,
				transform: `translateY(${virtualItem.start}px)`,
			}}
		>
			<TreeRow
				instance={instance}
				activeId={activeId}
				menuOpenId={menuOpenId}
				onContextMenu={onContextMenu}
				onLongPress={onLongPress}
				onFolderHover={onFolderHover}
				onNoteHover={onNoteHover}
			/>
		</div>
	);
}
