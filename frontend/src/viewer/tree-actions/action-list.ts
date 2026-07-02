const FILE_ACTIONS: readonly Action[] = [
	{ id: "rename", label: "Rename" },
	{ id: "move", label: "Move to…" },
	{ id: "duplicate", label: "Duplicate" },
	{ id: "copy-wikilink", label: "Copy wikilink" },
	{ id: "delete", label: "Delete", destructive: true },
];

const FOLDER_ACTIONS: readonly Action[] = [
	{ id: "rename", label: "Rename" },
	{ id: "move", label: "Move to…" },
	{ id: "delete", label: "Delete", destructive: true },
];

// Attachments are binary blobs — no duplicate/copy-wikilink.
const ATTACHMENT_ACTIONS: readonly Action[] = [
	{ id: "rename", label: "Rename" },
	{ id: "move", label: "Move to…" },
	{ id: "delete", label: "Delete", destructive: true },
];

export type ActionId = "rename" | "move" | "duplicate" | "copy-wikilink" | "delete";

export interface Action {
	id: ActionId;
	label: string;
	destructive?: boolean;
}

export function actionsFor({
	kind,
}: {
	kind: "file" | "folder" | "attachment";
}): readonly Action[] {
	if (kind === "folder") {
		return FOLDER_ACTIONS;
	}
	if (kind === "attachment") {
		return ATTACHMENT_ACTIONS;
	}
	return FILE_ACTIONS;
}
