import type { ItemInstance } from "@headless-tree/core";
import type { VirtualItem } from "@tanstack/react-virtual";
import type { LoaderItem } from "./loader";
import { TreeRow } from "./tree-row";

interface Props {
	virtualItem: VirtualItem;
	items: ItemInstance<LoaderItem>[];
	instanceFor?: (itemId: string) => ItemInstance<LoaderItem> | undefined;
	// The virtualizer's own measuring ref. Attaching it makes each slot as tall
	// as the row actually renders, instead of trusting `estimateSize`.
	measureElement?: (el: HTMLElement | null) => void;
	onContextMenu?: (itemId: string, x: number, y: number) => void;
	onLongPress?: (itemId: string) => void;
	onFolderHover?: (folderId: string) => void;
}

export function TreeRowVirtualized({
	virtualItem,
	items,
	instanceFor,
	measureElement,
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
			// Measured, not sized. `estimateSize` only positions the row until this
			// lands; a hardcoded height here would silently clip or overlap whenever
			// the row renders taller than the estimate (a font-size change on the
			// tree container is enough).
			ref={measureElement}
			data-index={virtualItem.index}
			// The gutter lives INSIDE the measured box, so it's part of the slot the
			// virtualizer reserves. A margin would sit outside the border-box that
			// ResizeObserver reports, and the rows would touch again.
			className="py-px"
			style={{
				position: "absolute",
				top: 0,
				left: 0,
				width: "100%",
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
