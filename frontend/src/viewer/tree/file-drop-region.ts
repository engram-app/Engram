import { createContext } from "react";

interface Row {
	kind: string;
	path: string;
}

// A dragged OS file can only land in a FOLDER. Whatever row the pointer is over,
// its target is that row's folder (a folder row is its own; a note or attachment
// row is its parent's). The tree outlines that folder and everything under it.

export interface FileDropTarget {
	/** Folder path being aimed at ("" = vault root), or null when no file is over the tree. */
	folder: string | null;
	setFolder: (folder: string | null) => void;
}

export const FileDropTargetContext = createContext<FileDropTarget>({
	folder: null,
	setFolder: () => undefined,
});

/** The folder a file dropped on `row` would land in. */
export function dropFolderFor(row: Row): string {
	if (row.kind === "folder") {
		return row.path;
	}
	const slash = row.path.lastIndexOf("/");
	return slash < 0 ? "" : row.path.slice(0, slash);
}

/**
 * Index range [start, end] of the visible rows that make up `folder`: its own row
 * plus every row beneath it. Null for the vault root (the whole tree) or when the
 * folder is not in the list.
 */
export function folderRegion(rows: Row[], folder: string): { start: number; end: number } | null {
	if (folder === "") {
		return null;
	}
	const start = rows.findIndex((r) => r.kind === "folder" && r.path === folder);
	if (start < 0) {
		return null;
	}
	let end = start;
	while (rows[end + 1]?.path.startsWith(`${folder}/`)) {
		end++;
	}
	return { start, end };
}
