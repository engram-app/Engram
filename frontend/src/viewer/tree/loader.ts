import {
	type AttachmentSummary,
	type Folder,
	type NoteSummary,
	ROOT_FOLDER_ID,
} from "../../api/queries";
import { noteName } from "../../lib/note-name";
import type { TreeItem } from "./types";
import { formatItemId, parseItemId, ROOT_ID } from "./types";

interface LoaderDeps {
	folders: Folder[];
	// Every note in the vault, already derived from the one vault-tree cache by
	// the caller. The loader used to hold a QueryClient and pull a per-folder
	// list out of react-query, fetching on a miss — which made it an async data
	// source that could answer "no notes" for a folder that has some. It is now
	// a pure function of what the caller already has.
	notes: NoteSummary[];
	sort: SortKey;
	attachments?: AttachmentSummary[];
}

function folderLoaderItem(deps: LoaderDeps, id: string): LoaderItem | undefined {
	const f = deps.folders.find((x) => x.id === id);
	if (!f) {
		return;
	}
	return {
		itemId: formatItemId({ kind: "folder", id: f.id }),
		item: {
			kind: "folder",
			id: f.id,
			path: f.name, // backend `name` IS the path
			name: f.name.split("/").pop() ?? f.name, // leaf name for display
			count: f.count,
		},
		isFolder: true,
	};
}

function noteLoaderItem(deps: LoaderDeps, id: string): LoaderItem | undefined {
	const hit = deps.notes.find((n) => n.id === id);
	return hit
		? { itemId: formatItemId({ kind: "note", id }), item: noteToTreeItem(hit), isFolder: false }
		: undefined;
}

function folderLoaderItems(deps: LoaderDeps, parentId: string | null): LoaderItem[] {
	return deps.folders
		.filter((f) => f.parent_id === parentId)
		.sort((a, b) => folderCmp(a, b, deps.sort))
		.map((f) => ({
			itemId: formatItemId({ kind: "folder", id: f.id }),
			item: {
				kind: "folder" as const,
				id: f.id,
				path: f.name,
				name: f.name.split("/").pop() ?? f.name,
				count: f.count,
			},
			isFolder: true,
		}));
}

// Note children for a folder id (ROOT_FOLDER_ID for the vault root).
//
// Always an answer, never a miss. The caller holds every note in the vault, so
// "this folder has no notes" is knowable without asking anyone — which is what
// removed the lazy fetch, the `onChildrenLoaded` callback and the
// `invalidateChildrenIds` re-ask that used to follow it.
function noteChildItems(deps: LoaderDeps, folderId: string): LoaderItem[] {
	const path = folderId === ROOT_FOLDER_ID ? "" : folderPathOf(deps, folderId);
	if (path === null) {
		return [];
	}
	return sortNotes(
		deps.notes.filter((n) => folderOf(n.path) === path),
		deps.sort,
	).map((n) => ({
		itemId: formatItemId({ kind: "note", id: n.id }),
		item: noteToTreeItem(n),
		isFolder: false,
	}));
}

// The folder path a loader id stands for. `deps.folders` is post-`select`, so a
// derived folder already carries its stable `syn:<path>` id and its `name` IS
// the full path.
function folderPathOf(deps: LoaderDeps, folderId: string): string | null {
	return deps.folders.find((f) => f.id === folderId)?.name ?? null;
}

function folderOf(path: string): string {
	const slash = path.lastIndexOf("/");
	return slash < 0 ? "" : path.slice(0, slash);
}

function attachmentDir(path: string): string {
	const slash = path.lastIndexOf("/");
	return slash < 0 ? "" : path.slice(0, slash);
}

function attachmentToTreeItem(a: AttachmentSummary): Extract<TreeItem, { kind: "attachment" }> {
	return { kind: "attachment", id: a.id, path: a.path, mime: a.mime_type, size: a.size_bytes };
}

// Resolve an attachment item id back to its row. The HT bridge caches rows from
// getChildren, so this is only hit for ids HT knows before enumerating (rare),
// but it keeps getItem total over the whole TreeItem union.
function attachmentLoaderItem(deps: LoaderDeps, path: string): LoaderItem | undefined {
	const a = (deps.attachments ?? []).find((x) => x.path === path);
	if (!a) {
		return;
	}
	return {
		itemId: formatItemId({ kind: "attachment", path }),
		item: attachmentToTreeItem(a),
		isFolder: false,
	};
}

function attachmentItemsForDir(deps: LoaderDeps, dir: string): LoaderItem[] {
	const list = (deps.attachments ?? []).filter((a) => attachmentDir(a.path) === dir);
	const sign = deps.sort.endsWith("-desc") ? -1 : 1;
	const fname = (p: string) => p.split("/").pop() ?? p;
	// Honor the temporal sort key via `mtime` so attachments order consistently
	// with notes under modified-*. Attachments carry no created_at, so created-*
	// (and name-*) fall back to filename.
	const cmp = deps.sort.startsWith("modified")
		? (a: AttachmentSummary, b: AttachmentSummary) => sign * (a.mtime - b.mtime)
		: (a: AttachmentSummary, b: AttachmentSummary) =>
				sign * fname(a.path).localeCompare(fname(b.path));
	return list.sort(cmp).map((a) => ({
		itemId: formatItemId({ kind: "attachment", path: a.path }),
		item: attachmentToTreeItem(a),
		isFolder: false,
	}));
}

function rootChildren(deps: LoaderDeps): LoaderItem[] {
	return [
		...folderLoaderItems(deps, null),
		...noteChildItems(deps, ROOT_FOLDER_ID),
		...attachmentItemsForDir(deps, ""),
	];
}

function folderChildren(deps: LoaderDeps, folderId: string): LoaderItem[] {
	const path = folderPathOf(deps, folderId);
	return [
		...folderLoaderItems(deps, folderId),
		...noteChildItems(deps, folderId),
		...(path === null ? [] : attachmentItemsForDir(deps, path)),
	];
}

function folderCmp(a: Folder, b: Folder, sort: SortKey): number {
	const dir = sort === "name-desc" ? -1 : 1;
	return dir * (a.name.split("/").pop() ?? a.name).localeCompare(b.name.split("/").pop() ?? b.name);
}

function sortNotes(notes: NoteSummary[], sort: SortKey): NoteSummary[] {
	const sign = sort.endsWith("-desc") ? -1 : 1;
	const copy = [...notes];
	if (sort.startsWith("modified")) {
		return copy.sort((a, b) => sign * (Date.parse(a.updated_at) - Date.parse(b.updated_at)));
	}
	if (sort.startsWith("created")) {
		return copy.sort((a, b) => sign * (Date.parse(a.created_at) - Date.parse(b.created_at)));
	}
	return copy.sort((a, b) => sign * noteName(a.path).localeCompare(noteName(b.path)));
}

function noteToTreeItem(n: NoteSummary): Extract<TreeItem, { kind: "note" }> {
	const last = n.path.split("/").pop() ?? n.path;
	const dot = last.lastIndexOf(".");
	const ext = dot > 0 ? last.slice(dot + 1).toLowerCase() : null;
	// Display name is always the filename, never the server-derived H1 title.
	return { kind: "note", id: n.id, path: n.path, title: noteName(n.path), ext };
}

export type SortKey =
	| "name-asc"
	| "name-desc"
	| "modified-asc"
	| "modified-desc"
	| "created-asc"
	| "created-desc";

export interface LoaderItem {
	itemId: string;
	item: TreeItem;
	isFolder: boolean;
}

export function buildLoader(deps: LoaderDeps) {
	return {
		getItem(itemId: string): LoaderItem | undefined {
			if (itemId === ROOT_ID) {
				return;
			}
			const p = parseItemId(itemId);
			if (p.kind === "root") {
				return;
			}
			if (p.kind === "folder") {
				return folderLoaderItem(deps, p.id);
			}
			if (p.kind === "note") {
				return noteLoaderItem(deps, p.id);
			}
			return attachmentLoaderItem(deps, p.path);
		},

		getChildren(itemId: string): LoaderItem[] {
			if (itemId === ROOT_ID) {
				return rootChildren(deps);
			}
			const p = parseItemId(itemId);
			if (p.kind !== "folder") {
				return [];
			}
			return folderChildren(deps, p.id);
		},
	};
}
