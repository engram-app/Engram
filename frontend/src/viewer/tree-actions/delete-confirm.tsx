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
			className="fixed inset-0 z-50 m-auto rounded-lg border border-border bg-popover p-4 text-popover-foreground shadow-xl"
		>
			<p className="mb-4 text-sm">{message}</p>
			<p className="mb-4 text-muted-foreground text-xs">This cannot be undone.</p>
			<div className="flex justify-end gap-2">
				<button
					type="button"
					onClick={onCancel}
					className="rounded border border-border px-3 py-1 text-sm hover:bg-accent hover:text-accent-foreground"
				>
					Cancel
				</button>
				<button
					type="button"
					onClick={onConfirm}
					className="rounded bg-destructive px-3 py-1 text-background text-sm hover:bg-destructive/90"
				>
					Delete
				</button>
			</div>
		</dialog>
	);
}
