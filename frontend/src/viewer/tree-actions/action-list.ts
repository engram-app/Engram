import {
	Copy,
	Eye,
	FilePlus,
	FileText,
	FolderInput,
	FolderPlus,
	Link2,
	ListPlus,
	type LucideIcon,
	Pencil,
	SquareCode,
	Trash2,
} from "lucide-react";

// Keyed by id rather than carried on each Action — the three lists below repeat
// the same ids, so one map keeps a single icon per action instead of three.
const ACTION_ICONS: Record<ActionId, LucideIcon> = {
	"new-note": FilePlus,
	"new-folder": FolderPlus,
	rename: Pencil,
	move: FolderInput,
	duplicate: Copy,
	"copy-wikilink": Link2,
	delete: Trash2,
	"add-property": ListPlus,
	"view-rendered": FileText,
	"view-raw": SquareCode,
	"view-reading": Eye,
};

const FILE_ACTIONS: readonly Action[] = [
	{ id: "rename", label: "Rename" },
	{ id: "move", label: "Move to…" },
	{ id: "duplicate", label: "Duplicate" },
	{ id: "copy-wikilink", label: "Copy wikilink" },
	{ id: "delete", label: "Delete", destructive: true },
];

// Creation first — the common right-click intent on a folder is "put something
// in here". These target the right-clicked folder, not the toolbar's active
// one, so the labels say "here" rather than reading as global actions.
const FOLDER_ACTIONS: readonly Action[] = [
	{ id: "new-note", label: "New note here" },
	{ id: "new-folder", label: "New subfolder" },
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

// Right-clicking empty tree space acts on the vault root. No rename/move/delete
// — the root isn't a folder you can address — so it's creation only, and the
// labels drop the "here" since there's no folder being pointed at.
const ROOT_ACTIONS: readonly Action[] = [
	{ id: "new-note", label: "New note" },
	{ id: "new-folder", label: "New folder" },
];

export type ActionId =
	| "new-note"
	| "new-folder"
	| "rename"
	| "move"
	| "duplicate"
	| "copy-wikilink"
	| "delete"
	| "add-property"
	| "view-rendered"
	| "view-raw"
	| "view-reading";

export interface Action {
	id: ActionId;
	label: string;
	destructive?: boolean;
	/** Set by `noteMenuActions` for the current view mode. The tree omits it. */
	active?: boolean;
}

// Every folder gets the same menu, derived or not. A derived folder has no id
// to send to the id-keyed batch endpoints, but rename, move and delete all have
// path-based routes (`POST /folders/rename`, `DELETE /folders/*path`), so the
// call site picks the right one — the user shouldn't see a lesser menu for a
// distinction that's purely about how the backend stores the folder.
export function actionsFor({
	kind,
}: {
	kind: "file" | "folder" | "attachment" | "root";
}): readonly Action[] {
	if (kind === "root") {
		return ROOT_ACTIONS;
	}
	if (kind === "folder") {
		return FOLDER_ACTIONS;
	}
	if (kind === "attachment") {
		return ATTACHMENT_ACTIONS;
	}
	return FILE_ACTIONS;
}

export type ViewMode = "rendered" | "raw" | "reading";

// The note page's kebab. Deliberately NOT part of `actionsFor` — that function
// answers "what can you do to a tree node", and the view modes are a property
// of the open editor, not of the file.
export function noteMenuActions(mode: ViewMode): readonly Action[] {
	return [
		{ id: "view-rendered", label: "Rendered", active: mode === "rendered" },
		{ id: "view-raw", label: "Raw", active: mode === "raw" },
		{ id: "view-reading", label: "Reading", active: mode === "reading" },
		{ id: "rename", label: "Rename" },
		{ id: "move", label: "Move to…" },
		{ id: "duplicate", label: "Duplicate" },
		{ id: "copy-wikilink", label: "Copy wikilink" },
		{ id: "add-property", label: "Add property" },
		{ id: "delete", label: "Delete", destructive: true },
	];
}

export { ACTION_ICONS };
