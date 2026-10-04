import { useMemo, useState } from "react";
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog";
import { useT } from "@/i18n/locale-provider";
import { FolderPicker } from "../attachment-upload/folder-picker";
import { isValidMoveTarget, type MoveNode } from "./move-path";

interface Props {
	folders: { name: string }[];
	nodes: MoveNode[];
	onPick: (folder: string) => void;
	onCancel: () => void;
}

function buildMessage(
	nodes: MoveNode[],
	{ t, tn }: Pick<ReturnType<typeof useT>, "t" | "tn">,
): string {
	if (nodes.length > 1) {
		return tn({ one: "Move {count} item to…", other: "Move {count} items to…" }, nodes.length);
	}
	return t("Move to…");
}

export function MoveDialog({ folders, nodes, onPick, onCancel }: Props) {
	const { t, tn } = useT();
	const title = buildMessage(nodes, { t, tn });

	// The vault root ("") is always a candidate, but it isn't a folder row, so
	// callers don't list it; add it here once rather than in every caller. A folder
	// is eligible only if it is a valid move target for EVERY node (which can rule
	// the root out too, e.g. a note already at the top level).
	const eligible = useMemo(
		() =>
			["", ...folders.map((f) => f.name).filter((name) => name !== "")].filter((name) =>
				nodes.every((node) => isValidMoveTarget(node, name)),
			),
		[folders, nodes],
	);
	const [active, setActive] = useState(eligible[0] ?? "");

	return (
		<Dialog open onOpenChange={(open) => !open && onCancel()}>
			<DialogContent
				aria-describedby={undefined}
				showCloseButton={false}
				className="flex h-[min(28rem,80vh)] max-w-md flex-col"
			>
				<DialogTitle className="text-sm">{title}</DialogTitle>
				<FolderPicker
					folders={eligible.filter((name) => name !== "")}
					includeRoot={eligible.includes("")}
					value={active}
					onChange={setActive}
					onActivate={onPick}
					placeholder={title}
					className="flex-1"
				/>
			</DialogContent>
		</Dialog>
	);
}
