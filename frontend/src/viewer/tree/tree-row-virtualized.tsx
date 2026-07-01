import type { ItemInstance } from "@headless-tree/core";
import type { VirtualItem } from "@tanstack/react-virtual";
import type { LoaderItem } from "./loader";
import { TreeRow } from "./tree-row";

interface Props {
	virtualItem: VirtualItem;
	items: ItemInstance<LoaderItem>[];
	instanceFor?: (itemId: string) => ItemInstance<LoaderItem> | undefined;
	onContextMenu?: (itemId: string, x: number, y: number) => void;
	onLongPress?: (itemId: string) => void;
	onFolderHover?: (folderId: string) => void;
}

export function TreeRowVirtualized({
	virtualItem,
	items,
	instanceFor,
	onContextMenu,
	onLongPress,
	onFolderHover,
}: Props) {
	const fallback = items[virtualItem.index];
	if (!fallback) {
		return null;
	}
	const instance = instanceFor ? (instanceFor(fallback.getId()) ?? fallback) : fallback;

	return (
		<div
			style={{
				position: "absolute",
				top: 0,
				left: 0,
				width: "100%",
				height: virtualItem.size,
				transform: `translateY(${virtualItem.start}px)`,
			}}
		>
			<TreeRow
				instance={instance}
				onContextMenu={onContextMenu}
				onLongPress={onLongPress}
				onFolderHover={onFolderHover}
			/>
		</div>
	);
}
