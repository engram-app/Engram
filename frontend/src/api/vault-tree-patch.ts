import type { VaultTree, VaultTreeAttachment, VaultTreeFolder, VaultTreeNote } from "./queries";

/**
 * Pure, optimistic edits to the ONE vault-tree cache entry.
 *
 * `['vault-tree', vaultId]` is the only client-side copy of the vault's
 * inventory; `useFolders`, `useAttachments`, `useVaultNotes` and the
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
 * Re-derive the folder rows from the notes actually in the tree.
 *
 * The server's rule (`combine_folders_payload/2`): a MARKER folder (non-null
 * id) is listed whether or not it holds anything; a DERIVED folder (null id)
 * is listed exactly when at least one note is filed directly in it, and
 * `count` is how many. Both halves are a function of `notes`, so they are
 * recomputed after every edit rather than adjusted by hand:
 *
 * - counts follow the notes, so no operation has to remember to decrement a
 *   source and increment a destination (what the old per-cache patches kept
 *   getting wrong);
 * - a note landing in a folder the tree has never seen gets its row, which is
 *   what makes a sync event for a note in a NEW folder render at all;
 * - a derived folder whose last note left disappears, as it will on the next
 *   fetch anyway, instead of lingering as an empty ghost.
 *
 * Ancestors and attachment-only folders are not rows on the wire either;
 * `synthesizeFolders` adds those downstream, so they are not handled here.
 */
function deriveFolders(folders: VaultTreeFolder[], notes: VaultTreeNote[]): VaultTreeFolder[] {
	const counts = new Map<string, number>();
	for (const n of notes) {
		const dir = dirOf(n.path);
		counts.set(dir, (counts.get(dir) ?? 0) + 1);
	}
	const out: VaultTreeFolder[] = [];
	for (const f of folders) {
		const next = counts.get(f.name) ?? 0;
		counts.delete(f.name);
		if (f.id === null && next === 0) {
			continue;
		}
		out.push(f.count === next ? f : { ...f, count: next });
	}
	// Whatever is left holds notes but had no row. The vault root has none on
	// purpose (its notes hang off the ROOT sentinel), so it never gets one.
	for (const [name, count] of counts) {
		if (name !== "") {
			out.push({ id: null, name, count, parent_id: null });
		}
	}
	return out;
}

function rebuild(
	notes: VaultTreeNote[],
	folders: VaultTreeFolder[],
	attachments: VaultTreeAttachment[],
): VaultTree {
	return { folders: deriveFolders(folders, notes), notes, attachments };
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

/**
 * A note-level change as the sync channel reports it. Only what the tree
 * needs survives classification; everything else about the event (content,
 * hashes, tags) belongs to other caches.
 */
export type NoteEvent =
	| { kind: "upsert"; id: string; path: string; updated_at?: string }
	| { kind: "delete"; id: string; path: string };

/**
 * Apply a burst of sync-channel note events to the tree in one pass, returning
 * the SAME tree when none of them changes anything, so observers don't redraw
 * for an echo of what they already show.
 *
 * Deletes are path-guarded. A rename reaches us as `delete(old path)` plus
 * `upsert(new path)` carrying the SAME id, and nothing orders the two legs.
 * Deleting by id alone would, when the upsert lands first, delete the note the
 * rename just moved; matching the path makes the legs commute.
 *
 * An upsert for an id the tree lacks inserts it. The event carries no
 * `created_at`, so a new row borrows `updated_at` until the next fetch; only
 * the "Created" sort can notice, and only until then.
 */
export function applyNoteEvents(tree: VaultTree, events: readonly NoteEvent[]): VaultTree {
	const byId = new Map(tree.notes.map((n) => [n.id, n]));
	let changed = false;
	for (const e of events) {
		const cur = byId.get(e.id);
		if (e.kind === "delete") {
			if (cur?.path === e.path) {
				byId.delete(e.id);
				changed = true;
			}
			continue;
		}
		const updatedAt = e.updated_at ?? cur?.updated_at ?? "";
		if (cur && cur.path === e.path && cur.updated_at === updatedAt && !cur.pending) {
			continue;
		}
		// Replacing the row also clears `pending`: this is the server confirming
		// an optimistic create.
		byId.set(e.id, {
			id: e.id,
			path: e.path,
			created_at: cur?.created_at ?? updatedAt,
			updated_at: updatedAt,
		});
		changed = true;
	}
	return changed ? rebuild([...byId.values()], tree.folders, tree.attachments) : tree;
}

/**
 * True when any event moves an existing note into a DIFFERENT folder.
 *
 * The event stream describes notes, never folder markers. A folder rename is
 * broadcast as one upsert+delete pair per note inside it and nothing about the
 * marker row itself, so a client patching from events alone keeps the old
 * marker forever (markers stay listed when empty) next to the new derived
 * folder. A move out of a marker folder looks identical on the wire, and there
 * it is RIGHT to keep the marker — so the client cannot tell the two apart and
 * must ask the server. A rename that keeps the folder can't touch a marker and
 * is safe to patch.
 */
export function movesAcrossFolders(tree: VaultTree, events: readonly NoteEvent[]): boolean {
	const byId = new Map(tree.notes.map((n) => [n.id, n]));
	return events.some((e) => {
		if (e.kind !== "upsert") {
			return false;
		}
		const cur = byId.get(e.id);
		return cur !== undefined && dirOf(cur.path) !== dirOf(e.path);
	});
}
