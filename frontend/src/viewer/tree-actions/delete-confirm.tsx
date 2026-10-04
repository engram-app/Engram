import { Button } from "@/components/ui/button";
import {
	Dialog,
	DialogContent,
	DialogDescription,
	DialogFooter,
	DialogTitle,
} from "@/components/ui/dialog";

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
	return (
		<Dialog open onOpenChange={(open) => !open && onCancel()}>
			<DialogContent showCloseButton={false}>
				<DialogTitle className="text-sm">{buildMessage(nodes)}</DialogTitle>
				<DialogDescription className="text-xs">This cannot be undone.</DialogDescription>
				<DialogFooter>
					<Button variant="outline" size="sm" onClick={onCancel}>
						Cancel
					</Button>
					<Button variant="destructive" size="sm" onClick={onConfirm}>
						Delete
					</Button>
				</DialogFooter>
			</DialogContent>
		</Dialog>
	);
}
