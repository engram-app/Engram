import { useMemo, useState } from "react";
import { isValidMoveTarget, type MoveNode } from "./move-path";

interface Props {
	folders: { name: string }[];
	nodes: MoveNode[];
	onPick: (folder: string) => void;
	onCancel: () => void;
}

function buildMessage(nodes: MoveNode[]): string {
	if (nodes.length > 1) {
		return `Move ${nodes.length} items to…`;
	}
	return "Move to…";
}

export function MoveDialog({ folders, nodes, onPick, onCancel }: Props) {
	const [query, setQuery] = useState("");
	const [active, setActive] = useState(0);
	const placeholder = buildMessage(nodes);

	const candidates = useMemo(() => {
		// A folder is eligible only if it's a valid move target for EVERY node.
		const eligible = folders
			.map((f) => f.name)
			.filter((name) => nodes.every((node) => isValidMoveTarget(node, name)));
		if (!query) {
			return eligible;
		}
		const q = query.toLowerCase();
		return eligible.filter((name) => (name || "root").toLowerCase().includes(q));
	}, [folders, nodes, query]);

	return (
		<dialog
			open
			className="fixed inset-0 z-50 m-auto h-96 w-96 rounded-lg bg-white shadow-xl dark:bg-gray-900"
		>
			{nodes.length > 1 && (
				<p className="border-gray-200 border-b px-3 py-2 font-medium text-gray-800 text-sm dark:border-gray-700 dark:text-gray-100">
					{placeholder}
				</p>
			)}
			<input
				role="combobox"
				autoFocus
				value={query}
				onChange={(e) => {
					setQuery(e.target.value);
					setActive(0);
				}}
				onKeyDown={(e) => {
					if (e.key === "ArrowDown") {
						setActive((a) => Math.min(a + 1, candidates.length - 1));
					}
					if (e.key === "ArrowUp") {
						setActive((a) => Math.max(a - 1, 0));
					}
					if (e.key === "Enter" && candidates[active] !== undefined) {
						onPick(candidates[active]);
					}
					if (e.key === "Escape") {
						onCancel();
					}
				}}
				placeholder={placeholder}
				className="w-full border-gray-200 border-b bg-transparent p-3 text-sm outline-none dark:border-gray-700"
			/>
			<div role="listbox" className="max-h-72 overflow-y-auto py-1">
				{candidates.map((name, i) => (
					// biome-ignore lint/a11y/useFocusableInteractive lint/a11y/useKeyWithClickEvents: option in a combobox-controlled listbox; options are intentionally not individually focusable and keyboard activation is handled on the input above
					<div
						key={name || "__root__"}
						role="option"
						aria-selected={i === active}
						onClick={() => onPick(name)}
						className={`cursor-pointer px-3 py-1.5 text-sm ${
							i === active ? "bg-blue-50 dark:bg-blue-950" : ""
						}`}
					>
						{name === "" ? "/ (root)" : name}
					</div>
				))}
			</div>
		</dialog>
	);
}
