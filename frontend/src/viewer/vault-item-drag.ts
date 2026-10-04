import { noteName } from "../lib/note-name";

// What the sidebar tree puts on a drag so the editor can turn the drop into a
// link. The tree itself moves items through headless-tree's internal state, not
// dataTransfer, so this custom type does not affect tree-to-tree moves.
export const VAULT_ITEM_MIME = "application/x-engram-vault-item";

export interface DraggedVaultItem {
	kind: "note" | "attachment";
	path: string;
}

export function setDraggedItem(dt: DataTransfer, item: DraggedVaultItem): void {
	dt.setData(VAULT_ITEM_MIME, JSON.stringify(item));
}

export function readDraggedItem(dt: DataTransfer | null): DraggedVaultItem | null {
	const raw = dt?.getData(VAULT_ITEM_MIME);
	if (!raw) {
		return null;
	}
	try {
		const v: unknown = JSON.parse(raw);
		if (
			typeof v === "object" &&
			v !== null &&
			"kind" in v &&
			"path" in v &&
			(v.kind === "note" || v.kind === "attachment") &&
			typeof v.path === "string"
		) {
			return { kind: v.kind, path: v.path };
		}
	} catch {
		// malformed payload from some other page: not ours
	}
	return null;
}

/** Link text to insert for a dropped item: `[[Note]]`, or `![[file.png]]` (Obsidian-style). */
export function linkTextFor(item: DraggedVaultItem, attachments: { path: string }[]): string {
	if (item.kind === "note") {
		return `[[${noteName(item.path)}]]`;
	}
	const name = item.path.split("/").pop() ?? item.path;
	// Shortest form that still resolves to THIS file: the bare name only when no
	// other attachment shares it.
	const sameName = attachments.filter((a) => (a.path.split("/").pop() ?? a.path) === name);
	const target = sameName.length <= 1 ? name : item.path;
	return `![[${target}]]`;
}
