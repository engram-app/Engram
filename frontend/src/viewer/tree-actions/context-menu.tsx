import { useEffect } from "react";
import { ACTION_ICONS, type Action, type ActionId } from "./action-list";

interface Props {
	actions: readonly Action[];
	position: { x: number; y: number };
	onPick: (id: ActionId) => void;
	onClose: () => void;
}

export function ContextMenu({ actions, position, onPick, onClose }: Props) {
	useEffect(() => {
		const onKey = (e: KeyboardEvent) => {
			if (e.key === "Escape") {
				onClose();
			}
		};
		const onClick = (e: MouseEvent) => {
			if (!(e.target as HTMLElement).closest("[data-tree-context-menu]")) {
				onClose();
			}
		};
		document.addEventListener("keydown", onKey);
		document.addEventListener("mousedown", onClick);
		return () => {
			document.removeEventListener("keydown", onKey);
			document.removeEventListener("mousedown", onClick);
		};
	}, [onClose]);

	return (
		<div
			data-tree-context-menu
			role="menu"
			style={{ top: position.y, left: position.x }}
			// p-1 (not py-1) insets each item, so the hover fill floats inside the
			// menu instead of running edge to edge. Items drop to px-2 to keep the
			// label in the same place.
			className="fixed z-50 min-w-40 rounded border border-border bg-popover p-1 text-popover-foreground shadow-lg"
		>
			{actions.map((a) => {
				const Icon = ACTION_ICONS[a.id];
				return (
					<button
						key={a.id}
						type="button"
						role="menuitem"
						onClick={() => {
							onPick(a.id);
							onClose();
						}}
						className={`flex w-full items-center gap-2 rounded-sm px-2 py-1 text-left text-sm hover:bg-accent ${
							// Destructive keeps its red on hover — recolouring it to
							// accent-foreground would drop the one cue that this item
							// is the dangerous one, exactly when the cursor is on it.
							a.destructive ? "text-destructive" : "hover:text-accent-foreground"
						}`}
					>
						{/* aria-hidden so the menuitem's accessible name stays the label */}
						<Icon aria-hidden="true" className="h-3.5 w-3.5 shrink-0" />
						{a.label}
					</button>
				);
			})}
		</div>
	);
}
