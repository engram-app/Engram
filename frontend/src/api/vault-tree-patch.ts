import type { VaultTree, VaultTreeAttachment, VaultTreeFolder, VaultTreeNote } from "./queries";

/**
 * Pure, optimistic edits to the ONE vault-tree cache entry.
 *
 * `['vault-tree', vaultId]` is the only client-side copy of the vault's
 * inventory; `useFolders`, `useAttachments`, `useFolderNotesById` and the
 * sidebar tree loader are all views of it. So a mutation's `onMutate` patches
 * exactly one entry here, and every view follows. That is the whole point:
 * the previous design kept the same note list in four entries and made each
 * mutation hand-sync all of them, which is where four separate sidebar bugs
 * came from.
 *
 * Every function returns a NEW tree. React Query compares by reference to
 * decide whether to notify observers, so mutating in place would apply the
 * edit and render nothing.
 *
 * Rollback is a snapshot of the whole tree, not a computed inverse — two
 * overlapping mutations make an inverse wrong, and the tree is one object, so
 * snapshotting it is a single `getQueryData` call.
 */

// Private helpers first: `useExportsLast` requires every non-export statement
// to precede the exports. They call the exported path helpers below from
// inside their bodies, which is evaluated long after this module initialises.

// Re-root `path` from under `fromDir` to under `toDir`, preserving everything
// below the prefix. Only call on a path `isUnder(path, fromDir)` already accepts.
const rerootPath = (path: string, fromDir: string, toDir: string): string =>
	path === fromDir ? toDir : joinPath(toDir, path.slice(fromDir.length + 1));

/**
 * Recompute every folder row's `count` from the notes actually in the tree.
 *
 * `count` is "notes filed directly in this folder" (backend
 * `combine_folders_payload/2`), which is a derivation of `notes`, not
 * independent state. Recomputing it after each edit is why no operation here
 * has to remember to decrement a source folder and increment a destination —
 * that bookkeeping is what the old per-cache patches kept getting wrong.
 */
function recount(folders: VaultTreeFolder[], notes: VaultTreeNote[]): VaultTreeFolder[] {
	const counts = new Map<string, number>();
	for (const n of notes) {
		const dir = dirOf(n.path);
		counts.set(dir, (counts.get(dir) ?? 0) + 1);
	}
	return folders.map((f) => {
		const next = counts.get(f.name) ?? 0;
		return f.count === next ? f : { ...f, count: next };
	});
}

function rebuild(
	notes: VaultTreeNote[],
	folders: VaultTreeFolder[],
	attachments: VaultTreeAttachment[],
): VaultTree {
	return { folders: recount(folders, notes), notes, attachments };
}

export const dirOf = (path: string): string => {
	const slash = path.lastIndexOf("/");
	return slash < 0 ? "" : path.slice(0, slash);
};

export const baseOf = (path: string): string => path.slice(path.lastIndexOf("/") + 1);

export const joinPath = (dir: string, name: string): string =>
	dir === "" ? name : `${dir}/${name}`;

// True for the directory itself and anything nested below it. The `/` guard is
// load-bearing: a bare `startsWith` makes `Archive2024` a child of `Archive`.
export const isUnder = (path: string, dir: string): boolean =>
	dir === "" || path === dir || path.startsWith(`${dir}/`);

/** Insert a note, or replace the row already holding that id. */
export function upsertNote(tree: VaultTree, note: VaultTreeNote): VaultTree {
	const notes = tree.notes.some((n) => n.id === note.id)
		? tree.notes.map((n) => (n.id === note.id ? note : n))
		: [...tree.notes, note];
	return rebuild(notes, tree.folders, tree.attachments);
}

export function removeNotes(tree: VaultTree, ids: readonly string[]): VaultTree {
	const drop = new Set(ids);
	return rebuild(
		tree.notes.filter((n) => !drop.has(n.id)),
		tree.folders,
		tree.attachments,
	);
}

/**
 * Re-path notes by id. Covers rename (same folder, new leaf) and move (same
 * leaf, new folder) alike, because the backend treats both as one operation
 * (`crdt_create` at a new path) and so should the optimistic patch.
 *
 * Unknown ids are skipped rather than inserted: a rename of something the tree
 * has never seen is a bug upstream, and inventing a row here would put a note
 * in the sidebar that the next refetch silently deletes.
 */
export function renameNotes(
	tree: VaultTree,
	moves: ReadonlyArray<{ id: string; newPath: string }>,
): VaultTree {
	const byId = new Map(moves.map((m) => [m.id, m.newPath]));
	const notes = tree.notes.map((n) => {
		const next = byId.get(n.id);
		return next === undefined || next === n.path ? n : { ...n, path: next };
	});
	return rebuild(notes, tree.folders, tree.attachments);
}

/** Move notes by id into `destDir`, keeping each filename. */
export function moveNotes(tree: VaultTree, ids: readonly string[], destDir: string): VaultTree {
	const wanted = new Set(ids);
	const moves = tree.notes
		.filter((n) => wanted.has(n.id))
		.map((n) => ({ id: n.id, newPath: joinPath(destDir, baseOf(n.path)) }));
	return renameNotes(tree, moves);
}

/**
 * Delete folders and everything filed under them — descendant folder rows, the
 * notes inside, and the attachments inside.
 *
 * The recursion is implicit in `isUnder`, so a caller never has to collect
 * descendants itself. That collection step (`collectFolderDescendants`) existed
 * only because the old per-folder caches had to be located one key at a time.
 */
export function removeFolders(tree: VaultTree, paths: readonly string[]): VaultTree {
	const roots = paths.filter((p) => p !== "");
	if (roots.length === 0) {
		return tree;
	}
	const inside = (path: string) => roots.some((root) => isUnder(path, root));
	return rebuild(
		tree.notes.filter((n) => !inside(dirOf(n.path))),
		tree.folders.filter((f) => !inside(f.name)),
		tree.attachments.filter((a) => !inside(dirOf(a.path))),
	);
}

/**
 * Re-path folders and their whole subtree. Handles rename (new leaf name) and
 * move (new parent) identically, and carries notes, attachments and descendant
 * folder rows along with the folder.
 */
export function renameFolders(
	tree: VaultTree,
	moves: ReadonlyArray<{ oldPath: string; newPath: string }>,
): VaultTree {
	const real = moves.filter((m) => m.oldPath !== "" && m.oldPath !== m.newPath);
	if (real.length === 0) {
		return tree;
	}
	// First match wins. Nested sources (`a` and `a/b` in one batch) would
	// otherwise re-path twice and land somewhere neither move asked for.
	const reroot = (path: string): string => {
		const hit = real.find((m) => isUnder(path, m.oldPath));
		return hit ? rerootPath(path, hit.oldPath, hit.newPath) : path;
	};
	const movePath = (path: string): string => joinPath(reroot(dirOf(path)), baseOf(path));
	return rebuild(
		tree.notes.map((n) => {
			const next = movePath(n.path);
			return next === n.path ? n : { ...n, path: next };
		}),
		tree.folders.map((f) => {
			const next = reroot(f.name);
			return next === f.name ? f : { ...f, name: next };
		}),
		tree.attachments.map((a) => {
			const next = movePath(a.path);
			return next === a.path ? a : { ...a, path: next };
		}),
	);
}

/** Move folders into `destDir`, keeping each folder's own leaf name. */
export function moveFolders(tree: VaultTree, paths: readonly string[], destDir: string): VaultTree {
	return renameFolders(
		tree,
		paths.map((oldPath) => ({ oldPath, newPath: joinPath(destDir, baseOf(oldPath)) })),
	);
}
