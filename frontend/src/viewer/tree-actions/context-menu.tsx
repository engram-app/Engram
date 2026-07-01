import { useEffect } from "react";
import type { Action, ActionId } from "./action-list";

interface Props {
	actions: readonly Action[];
	position: { x: number; y: number };
	onPick: (id: ActionId) => void;
	onClose: () => void;
}

export function ContextMenu({ actions, position, onPick, onClose }: Props) {
	useEffect(() => {
		const onKey = (e: KeyboardEvent) => {
			if (e.key === "Escape") onClose();
		};
		const onClick = (e: MouseEvent) => {
			if (!(e.target as HTMLElement).closest("[data-tree-context-menu]")) onClose();
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
			className="fixed z-50 min-w-40 rounded border border-gray-200 bg-white py-1 shadow-lg dark:border-gray-700 dark:bg-gray-800"
		>
			{actions.map((a) => (
				<button
					key={a.id}
					type="button"
					role="menuitem"
					onClick={() => {
						onPick(a.id);
						onClose();
					}}
					className={`flex w-full px-3 py-1 text-left text-sm hover:bg-gray-100 dark:hover:bg-gray-700 ${
						a.destructive ? "text-red-600 dark:text-red-400" : "text-gray-800 dark:text-gray-100"
					}`}
				>
					{a.label}
				</button>
			))}
		</div>
	);
}
