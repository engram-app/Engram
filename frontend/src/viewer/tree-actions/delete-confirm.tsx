type Node = { kind: "file"; path: string } | { kind: "folder"; path: string; childCount: number };

interface Props {
	nodes: Node[];
	onConfirm: () => void;
	onCancel: () => void;
}

function buildMessage(nodes: Node[]): string {
	if (nodes.length > 1) {
		return `Delete ${nodes.length} items?`;
	}
	const [node] = nodes;
	if (!node) {
		return "Delete?";
	}
	return node.kind === "file"
		? `Delete ${node.path}?`
		: `Delete ${node.path}/ and ${node.childCount} items?`;
}

export function DeleteConfirm({ nodes, onConfirm, onCancel }: Props) {
	const message = buildMessage(nodes);

	return (
		<dialog
			open
			className="fixed inset-0 z-50 m-auto rounded-lg bg-white p-4 shadow-xl dark:bg-gray-900"
		>
			<p className="mb-4 text-gray-800 text-sm dark:text-gray-100">{message}</p>
			<p className="mb-4 text-gray-500 text-xs dark:text-gray-400">This cannot be undone.</p>
			<div className="flex justify-end gap-2">
				<button
					type="button"
					onClick={onCancel}
					className="rounded border border-gray-300 px-3 py-1 text-sm dark:border-gray-700"
				>
					Cancel
				</button>
				<button
					type="button"
					onClick={onConfirm}
					className="rounded bg-red-600 px-3 py-1 text-sm text-white hover:bg-red-700"
				>
					Delete
				</button>
			</div>
		</dialog>
	);
}
