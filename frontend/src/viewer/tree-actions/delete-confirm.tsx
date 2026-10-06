import { Button } from "@/components/ui/button";
import {
	Dialog,
	DialogContent,
	DialogDescription,
	DialogFooter,
	DialogTitle,
} from "@/components/ui/dialog";
import { useT } from "@/i18n/locale-provider";

type Node = { kind: "file"; path: string } | { kind: "folder"; path: string; childCount: number };

interface Props {
	nodes: Node[];
	onConfirm: () => void;
	onCancel: () => void;
}

function buildMessage(nodes: Node[], { t, tn }: Pick<ReturnType<typeof useT>, "t" | "tn">): string {
	if (nodes.length > 1) {
		return tn({ one: "Delete {count} item?", other: "Delete {count} items?" }, nodes.length);
	}
	const [node] = nodes;
	if (!node) {
		return t("Delete?");
	}
	return node.kind === "file"
		? t("Delete {path}?", { path: node.path })
		: tn(
				{ one: "Delete {path}/ and {count} item?", other: "Delete {path}/ and {count} items?" },
				node.childCount,
				{ path: node.path },
			);
}

export function DeleteConfirm({ nodes, onConfirm, onCancel }: Props) {
	const { t, tn } = useT();
	return (
		<Dialog open onOpenChange={(open) => !open && onCancel()}>
			<DialogContent showCloseButton={false}>
				<DialogTitle className="text-sm">{buildMessage(nodes, { t, tn })}</DialogTitle>
				<DialogDescription className="text-xs">{t("This cannot be undone.")}</DialogDescription>
				<DialogFooter>
					<Button variant="outline" onClick={onCancel}>
						{t("Cancel")}
					</Button>
					<Button variant="destructive" onClick={onConfirm}>
						{t("Delete")}
					</Button>
				</DialogFooter>
			</DialogContent>
		</Dialog>
	);
}
