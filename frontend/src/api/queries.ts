import {
	keepPreviousData,
	type QueryClient,
	useMutation,
	useQuery,
	useQueryClient,
} from "@tanstack/react-query";
import { useCallback } from "react";
import { useNavigate } from "react-router";
import { toast } from "sonner";
import { collideBump } from "@/lib/collide-bump";
import { noteName } from "@/lib/note-name";
import { randomUuid } from "@/lib/random-uuid";
import { uuid7 } from "../crdt/uuid7";
import { noteHref } from "../routes";
import {
	isSyntheticFolderId,
	syntheticFolderId,
	syntheticFolderPath,
} from "../viewer/tree/synthesize-folders";
import type { NoteLinkEdge } from "../viewer/wiki-link";
import { reconcileActiveVault, useActiveVaultId } from "./active-vault";
import { crdtCreateNote, crdtCreateNoteWithContent, crdtDeleteNote } from "./channel";
import { ApiError, api } from "./client";
import { CrdtOpError } from "./crdt-ops";
import {
	baseOf,
	// Path → parent folder, the same rule the backend uses when computing
	// `folder` on a NoteSummary. One definition, shared with the tree patches
	// so a path can't mean two things on the two sides of a mutation.
	dirOf as folderOf,
	isUnder,
	joinPath,
	moveFolders,
	moveNotes,
	removeFolders,
	removeNotes,
	renameFolders,
	renameNotes,
	upsertNote,
} from "./vault-tree-patch";

// Encode each path segment but preserve slashes so Phoenix's splat
// routes match. encodeURIComponent on a full path produces %2F, which
// Plug.Static rejects with 400 InvalidPathError before the router runs.
function encodePathSegments(path: string): string {
	return path.split("/").map(encodeURIComponent).join("/");
}

// Hoisted so React Query treats the select identity as stable; otherwise an
// inline arrow re-runs every render and returns a fresh array, breaking
// memoized consumers (e.g. useEngramTree's rebuild useEffect).
// Drop only the root row; give derived folders a stable synthetic id keyed on
// their path so the `Folder.id: string` contract holds and they aren't erased
// from the tree. synthesizeFolders then links parents/ancestors.
const selectFolders = (tree: VaultTree): Folder[] =>
	tree.folders
		.filter((f) => f.name !== "")
		.map((f) => ({ ...f, id: f.id ?? syntheticFolderId(f.name) }));

const selectNotes = (data: { notes: NoteSummary[] }) => data.notes;

const selectAttachments = (tree: VaultTree): AttachmentSummary[] => tree.attachments;

// Every note in the vault, in the shape list consumers render. The sidebar
// tree takes this whole array and filters per folder itself, which is cheaper
// than a query per folder and cannot go stale relative to its siblings.
const selectAllNotes = (tree: VaultTree): NoteSummary[] => tree.notes.map(treeNoteToSummary);

// Single source for the by-id note fetch used by useNote's queryFn.
function fetchNoteById(id: string): Promise<Note> {
	return api.get<Note>(`/notes/by-id/${id}`);
}

/**
 * Every optimistic mutation rolls back the same way now: put the one
 * `['vault-tree', vaultId]` snapshot back. A context only carries more than
 * that where a genuinely separate cache is involved — the note BODY
 * (`['note', vaultId, id]`), which holds content the tree does not.
 */
interface TreeContext {
	tree: VaultTree | undefined;
	// What the optimistic patch wrote. `onError` restores only if this is still
	// what's in the cache — see `restoreTree`.
	patched: VaultTree | undefined;
}

interface CreateNoteContext extends TreeContext {
	id: string;
}

// 409/404/etc → human-grade toast copy. Centralised so all four
// mutations (and the standalone drop handler) speak the same dialect.
// Shared by note rename (CRDT → CrdtOpError) and folder/attachment rename
// (REST → ApiError). A note's target-occupied conflict surfaces as
// crdt_create's `create_failed`; the REST paths use HTTP 409/404.
function renameErrorToast(err: unknown, kind: "file" | "folder") {
	const noun = kind === "file" ? "note" : "folder";
	const conflict =
		(err instanceof ApiError && err.status === 409) ||
		(err instanceof CrdtOpError && err.reason === "create_failed");
	const gone = err instanceof ApiError && err.status === 404;
	if (conflict) {
		toast.error(`A ${noun} with that name already exists.`);
	} else if (gone) {
		toast.error(`${noun[0]?.toUpperCase()}${noun.slice(1)} no longer exists.`);
	} else {
		toast.error("Rename failed.");
	}
}

function deleteErrorToast(err: ApiError, kind: "file" | "folder") {
	const noun = kind === "file" ? "Note" : "Folder";
	if (err.status === 404) {
		toast.error(`${noun} no longer exists.`);
	} else {
		toast.error("Delete failed.");
	}
}

// The note id is stable across a rename, so only the BODY cache needs its own
// snapshot: rollback has to restore `path`/`folder` under the same key.
interface NoteBodyContext extends TreeContext {
	noteId: string;
	prevNote: Note | undefined;
}

interface DuplicateNoteContext extends TreeContext {
	placeholderId: string;
}

function idempotencyHeaders(): { headers: Record<string, string> } {
	return { headers: { "X-Idempotency-Key": randomUuid() } };
}

// Folder ids as the TREE holds them (a real marker id, else `syn:<path>`),
// resolved to the paths every tree patch works in. Ids the tree doesn't know
// are dropped: there is nothing to patch for them, and the settle refetch
// reconciles whatever the server did.
function folderPathsForIds(tree: VaultTree | undefined, ids: readonly string[]): string[] {
	if (!tree) {
		return [];
	}
	return ids
		.map((id) => folderPathForId(tree, id))
		.filter((path): path is string => path !== null && path !== "");
}

// Bumped by `invalidateVaultTree` — the single chokepoint every tree
// invalidation goes through, from `api/channel.ts` and from every mutation.
// `fetchVaultTreeFresh` reads it to tell whether a change landed while its
// request was in flight. Module-global rather than per-vault: a vault switch
// costs at most one extra refetch, which is not worth a Map to avoid.
let treeInvalidationGen = 0;

// Cap on consecutive "the tree I just fetched is already out of date" retries.
// ponytail: 3 is a backstop against a pathological event storm, not a tuning
// knob — the loop's own exit condition is what normally ends it. Past the cap
// we keep the newest snapshot we have; the NEXT invalidation then lands on a
// query that HAS data, which query-core restarts properly (Query.fetch takes
// the `cancel({silent:true})` branch when `cancelRefetch` is set, which
// `refetchQueries` defaults to true). So exceeding the cap degrades to the
// already-correct steady-state path, never to a hang.
const MAX_STALE_TREE_REFETCHES = 3;

/**
 * Fetch the vault tree, re-fetching if an invalidation landed mid-flight.
 *
 * This closes the one window the derived-query redesign left open. On the
 * FIRST-EVER fetch `state.data === undefined`, so `Query.fetch` takes the
 * `return this.#retryer.promise` branch and COALESCES the invalidation onto
 * the in-flight request instead of restarting it — and the `success` dispatch
 * then sets `isInvalidated: false`. The result: a snapshot that predates the
 * event lands marked fresh, and nothing ever asks again. Verified against
 * @tanstack/query-core 5.101.4 `src/query.ts`.
 *
 * `change_seq` would be the natural detector, but no sync-channel event
 * carries a seq to compare it against (see the `VaultTree` note), so we detect
 * the invalidation itself rather than the staleness it implies.
 *
 * Convergence: `seen` is re-captured immediately BEFORE each retry request is
 * issued, so the loop exits as soon as one request completes with no
 * invalidation having arrived during it. The condition is equality against a
 * monotonically increasing counter — never a comparison of payload contents —
 * so it cannot oscillate between two states; each iteration strictly consumes
 * the generation value that triggered it.
 */
async function fetchVaultTreeFresh(): Promise<VaultTree> {
	let seen = treeInvalidationGen;
	let tree = await api.get<VaultTree>("/vault/tree");
	for (let i = 0; treeInvalidationGen !== seen && i < MAX_STALE_TREE_REFETCHES; i++) {
		seen = treeInvalidationGen;
		tree = await api.get<VaultTree>("/vault/tree");
	}
	return tree;
}

/**
 * A Note-shaped stand-in built from the vault tree, for a note we have not
 * fetched yet.
 *
 * The tree carries id/path/timestamps for every note in the vault, which is
 * everything NotePage's chrome renders. `content` is deliberately `""` and
 * `version` 0 (via `treeNoteToSummary`) — this value must never be written
 * back anywhere. It is safe today because nothing mutating reads them: the
 * duplicate mutation re-fetches its source over REST, and CRDT genesis seeds
 * from the Y.Doc's own text, never from this. Keep it that way.
 */
function noteFromVaultTree(
	qc: QueryClient,
	vaultId: string | null | undefined,
	id: string | null,
): Note | undefined {
	if (!id) {
		return;
	}
	const tree = qc.getQueryData<VaultTree>(["vault-tree", vaultId]);
	const row = tree?.notes.find((n) => n.id === id);
	return row ? { ...treeNoteToSummary(row), content: "" } : undefined;
}

// A `/vault/tree` note row in the `NoteSummary` shape every note-list cache
// carries. `title`/`tags`/`version` are not on the wire — see the controller
// moduledoc: the tree derives everything it renders from `path`.
function treeNoteToSummary(n: VaultTreeNote): NoteSummary {
	return {
		id: n.id,
		pending: n.pending,
		path: n.path,
		title: noteName(n.path),
		folder: folderOf(n.path),
		tags: [],
		version: 0,
		// Type divergence, not a bug (nothing reads NoteSummary.mtime today):
		// this is an ISO string, but a row fetched from /api/notes carries mtime
		// as an epoch float (note.ex's `mtime` field is `:float`). Don't do
		// arithmetic on this without normalizing first.
		mtime: n.updated_at,
		created_at: n.created_at,
		updated_at: n.updated_at,
	};
}

// Inverse of the id-keying every note-list cache uses: the vault root keys
// under the ROOT_FOLDER_ID sentinel (it has no marker row), a folder the
// backend returned with `id: null` — or one that only exists because a note
// sits in it — keys under `syn:<path>` exactly as synthesize-folders.ts
// derives, and everything else under its marker id. Null when the tree holds
// no such folder; the tree is the whole inventory, so that folder has no notes.
function folderPathForId(tree: VaultTree, folderId: string): string | null {
	if (folderId === ROOT_FOLDER_ID) {
		return "";
	}
	if (isSyntheticFolderId(folderId)) {
		return syntheticFolderPath(folderId);
	}
	return tree.folders.find((f) => f.id === folderId)?.name ?? null;
}

// Stable empty list. `notesInFolder` is a react-query `select`, so returning a
// fresh `[]` on every call would hand each observer a new reference and
// re-render every collapsed/empty folder on every tree change.
const NO_NOTES: NoteSummary[] = [];

/**
 * Snapshot the one cache entry, having stopped anything in flight from
 * clobbering the patch that follows. The whole optimistic protocol is now
 * snapshot → patch → restore-on-error against a single key, which is why
 * every mutation's `onMutate` below is a handful of lines rather than the
 * per-cache bookkeeping this replaced.
 */
async function snapshotTree(
	qc: QueryClient,
	vaultId: string | null | undefined,
): Promise<VaultTree | undefined> {
	await qc.cancelQueries({ queryKey: ["vault-tree", vaultId] });
	return qc.getQueryData<VaultTree>(["vault-tree", vaultId]);
}

// Returns what it wrote, so `restoreTree` can tell "still mine" from
// "something else has landed since".
function patchTree(
	qc: QueryClient,
	vaultId: string | null | undefined,
	fn: (tree: VaultTree) => VaultTree,
): VaultTree | undefined {
	return qc.setQueryData<VaultTree>(["vault-tree", vaultId], (tree) => (tree ? fn(tree) : tree));
}

/**
 * Put a snapshot back, but ONLY if the tree is still exactly what this
 * mutation left there.
 *
 * The identity check is the price of collapsing four caches into one. Before,
 * two mutations touching different folders snapshotted different entries, so
 * rolling back one could not undo the other. Now they share an object, and an
 * unconditional restore would revert whatever landed in between — a second
 * mutation's optimistic patch, or a refetch carrying newer server state.
 *
 * Skipping the restore is the safe branch, not a silent failure: every caller
 * stales the tree in `onSettled`, so the refetch reconciles. Rolling back to a
 * computed inverse instead would be worse; an inverse is wrong exactly when
 * two mutations overlap, which is the case this guard exists for.
 *
 * `undefined` means the tree wasn't cached when the mutation started, so there
 * is nothing to put back.
 */
function restoreTree(
	qc: QueryClient,
	vaultId: string | null | undefined,
	snapshot: VaultTree | undefined,
	patched: VaultTree | undefined,
): void {
	if (snapshot === undefined) {
		return;
	}
	const current = qc.getQueryData<VaultTree>(["vault-tree", vaultId]);
	if (patched !== undefined && current !== patched) {
		return;
	}
	qc.setQueryData<VaultTree>(["vault-tree", vaultId], snapshot);
}

// Types matching backend JSON responses
//
// `name` carries the FULL folder path (e.g. `'top/sub'`) — load-bearing
// for legacy path-keyed consumers. `id` + `parent_id` were added by
// backend commit 935b7bbf so headless-tree can key nodes by id and
// discover tree shape via parent_id without parsing path strings.
export interface Folder {
	id: string;
	parent_id: string | null;
	name: string;
	count: number;
}

export interface NoteSummary {
	id: string;
	// Client-only: set on an optimistic row whose create hasn't been acked yet.
	// The row already carries its FINAL id (we mint it), so the id can no longer
	// signal "not real yet" — this flag does.
	pending?: boolean;
	path: string;
	title: string;
	folder: string;
	tags: string[];
	version: number;
	mtime: string;
	created_at: string;
	updated_at: string;
}

export interface Note extends NoteSummary {
	content: string;
	// Optional: older cached payloads (pre note-links backend rollout) lack it.
	links?: NoteLinkEdge[];
}

export interface SearchResult {
	// null for orphan path hits (Task 1 backend) — frontend should treat
	// these as non-clickable since there's no id-routable target.
	id: string | null;
	path: string;
	title: string;
	folder: string;
	heading_path: string | null;
	snippet: string;
	score: number;
	match_count: number;
}

export interface User {
	id: string;
	email: string;
	role: "admin" | "member";
	display_name: string | null;
}

// Query hooks

export function useFolders() {
	const vaultId = useActiveVaultId();
	// A VIEW of the one vault-tree entry, not a cache of its own. `select` is
	// observer-level, so this shares the tree's single Query object: one fetch,
	// one thing to invalidate, and one thing a mutation has to patch.
	//
	// `enabled`: ungated, a deep link arriving before the bootstrap reconcile
	// would fetch (and server-side decrypt) some other vault's whole inventory.
	return useQuery({
		...vaultTreeQueryOptions(vaultId),
		enabled: Boolean(vaultId),
		select: selectFolders,
	});
}

export function useFolderNotes(folder: string, options?: { enabled?: boolean }) {
	const vaultId = useActiveVaultId();
	return useQuery({
		queryKey: ["folderNotes", vaultId, folder],
		queryFn: () =>
			api.get<{ notes: NoteSummary[] }>(`/folders/list?folder=${encodeURIComponent(folder)}`),
		select: selectNotes,
		enabled: options?.enabled ?? folder.length > 0,
		// Same contract as useFolderNotesById: mutations + channel events
		// invalidate; staleness only spans gaps those already don't cover.
		staleTime: FOLDER_NOTES_STALE_MS,
	});
}

// Headless-tree consumers key folder nodes by id and fetch their note
// children via the by-id endpoint (Task 6). Path-keyed `useFolderNotes`
// stays in place for the dashboard folder-browse view; the tree reads
// everything (root + subfolders) through this one id-keyed cache so a
// note mutation only has to patch a single place.
// 60s of staleness keeps re-expansions instant while a `notes.batch` channel
// event (or any single-note mutation) still invalidates the key and refetches.
export const FOLDER_NOTES_STALE_MS = 60_000;

export interface AttachmentSummary {
	id: string;
	path: string;
	mime_type: string;
	size_bytes: number;
	mtime: number;
	updated_at: string;
}

export function useAttachments() {
	const vaultId = useActiveVaultId();
	return useQuery({
		...vaultTreeQueryOptions(vaultId),
		enabled: Boolean(vaultId),
		select: selectAttachments,
	});
}

// Wikilink resolution (wiki-link-redirect.tsx) needs the vault-wide path→id
// inventory; the sync manifest is the one endpoint that has it. Also fetched
// on note mount (note-page.tsx) to feed [[ autocomplete (wiki-completion.ts).
// The 30s staleTime bounds both: link-hopping and repeated note mounts don't
// re-pull a large vault's manifest more than once per that window.
export function useSyncManifest() {
	const vaultId = useActiveVaultId();
	return useQuery({
		queryKey: ["syncManifest", vaultId],
		queryFn: () => api.get<{ notes: { id: string; path: string }[] }>("/sync/manifest"),
		staleTime: 30_000,
	});
}

export function useUploadAttachment() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<
		{ attachment: AttachmentSummary },
		Error,
		{ path: string; mime_type?: string; content_base64: string; mtime: number }
	>({
		mutationFn: (body) => api.post<{ attachment: AttachmentSummary }>("/attachments", body),
		onSuccess: () => {
			// New attachment row changes the tree's attachment list, its folder's
			// count, AND the dashboard folder-browse list (which renders attachments).
			// Mirrors useBatchDeleteAttachments — keep all three keys in sync.
			// 402s (disabled / text-only / too-large / quota) throw LimitExceededError
			// AND open the global UpgradeRequiredDialog via the client's
			// upgradeHandler — nothing to handle here.
			invalidateVaultTree(qc, vaultId);
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
		},
	});
}

// The vault root has no folder-marker row (the by-id endpoint requires a
// non-null id), so it keys its note list under this sentinel — the same value
// the backend already uses as the batch-move root target. One id-space, one
// shape (`NoteSummary[]`), for every folder including root.
export const ROOT_FOLDER_ID = "root";

/**
 * One folder's notes, as a view of the vault tree.
 *
 * There is no `['folder-notes-by-id', ...]` cache any more. It used to hold a
 * per-folder copy that the sidebar loader filled with `fetchQuery` and read
 * with `getQueryData`, never mounting an observer — so react-query's `gcTime`
 * deleted the folder the user was looking at every five minutes, and every
 * mutation had to hand-patch each copy it could find. Deriving on read costs
 * one filter over an array the client already holds.
 */
export function notesInFolder(tree: VaultTree, folderId: string): NoteSummary[] {
	const path = folderPathForId(tree, folderId);
	if (path === null) {
		return NO_NOTES;
	}
	const rows = tree.notes.filter((n) => folderOf(n.path) === path);
	return rows.length === 0 ? NO_NOTES : rows.map(treeNoteToSummary);
}

export function useVaultNotes() {
	const vaultId = useActiveVaultId();
	return useQuery({
		...vaultTreeQueryOptions(vaultId),
		enabled: Boolean(vaultId),
		select: selectAllNotes,
	});
}

export function useFolderNotesById(folderId: string | null, opts: { enabled?: boolean } = {}) {
	const vaultId = useActiveVaultId();
	// Memoized on folderId so react-query can cache the select result; an inline
	// arrow would re-derive (and hand back a new array) on every render.
	const select = useCallback((tree: VaultTree) => notesInFolder(tree, folderId ?? ""), [folderId]);
	return useQuery({
		...vaultTreeQueryOptions(vaultId),
		enabled: folderId !== null && Boolean(vaultId) && (opts.enabled ?? true),
		select,
	});
}

// GET /api/vault/tree row shapes (deliberately thin — see the controller's
// moduledoc: title/tags/version/mtime are omitted, the tree derives them from
// `path`). Distinct from `Folder`/`NoteSummary`/`AttachmentSummary`, which are
// the shapes the REST-per-folder hooks (and their caches) already carry.
export interface VaultTreeFolder {
	id: string | null;
	name: string;
	count: number;
	parent_id: string | null;
}
export interface VaultTreeNote {
	id: string;
	path: string;
	created_at: string;
	updated_at: string;
	// Set only on an optimistic row this client just created, and cleared when
	// the server's version lands. `realFilenames`-style collision checks skip
	// pending rows so our own placeholder doesn't bump the name we ask for.
	pending?: boolean;
}
export interface VaultTreeAttachment {
	id: string;
	path: string;
	mime_type: string;
	size_bytes: number;
	mtime: number;
	updated_at: string;
}
// `change_seq` is deliberately NOT declared here even though the endpoint
// returns it. It is the vault's monotonic write watermark, and it would be the
// natural way to detect that a tree snapshot predates a change we already know
// about — except no `sync:` channel event carries a seq to compare it against.
// `note_changed` (upsert and delete), `notes.batch` and `folders.batch` all ship
// without one, so the client never holds a second value to put it next to.
// Declaring a field nothing can use invites exactly the wrong fix: comparing
// two consecutive tree payloads' `change_seq` and skipping the refetch when
// they match. See `fetchVaultTreeFresh` for what is used instead, and the
// redesign report for what stamping a seq onto the broadcasts would cost.
export interface VaultTree {
	folders: VaultTreeFolder[];
	notes: VaultTreeNote[];
	attachments: VaultTreeAttachment[];
}

/**
 * One request for the whole tree — see the controller moduledoc for why (this
 * replaced one HTTP round-trip per folder, 20-33 on a real vault).
 *
 * This query IS the source for `useFolders`, `useAttachments` and
 * `useFolderNotesById`: they derive their data from it instead of fetching
 * their own. Nothing writes into those caches sideways, so there is exactly one
 * place a stale sidebar can come from, and exactly one key to invalidate.
 *
 * Shared options rather than a hook alone, because the derived queryFns and the
 * tree loader all have to reach the SAME Query object.
 *
 * `staleTime` matches the derived views (FOLDER_NOTES_STALE_MS) on purpose.
 * Everything that can change the tree already invalidates this key —
 * `api/channel.ts` (note_changed / notes.batch / folders.batch / reconnect
 * backfill) and every mutation, via `invalidateVaultTree` — so 60s of
 * staleness only spans gaps nothing else would catch, and it is what lets a
 * folder expand (which fetches its derived note list) cost zero requests.
 */
export function vaultTreeQueryOptions(vaultId: string | null | undefined) {
	return {
		queryKey: ["vault-tree", vaultId] as const,
		queryFn: fetchVaultTreeFresh,
		staleTime: FOLDER_NOTES_STALE_MS,
	};
}

/**
 * Stale the vault tree, and with it every view of it.
 *
 * This is the ONLY sidebar invalidation there is. `useFolders`,
 * `useAttachments`, `useVaultNotes` and `useFolderNotesById` are `select`
 * views of this one query, not caches of their own, so there is nothing else
 * to stale and no ordering to get wrong.
 *
 * The generation bump is what makes this work against a tree request that is
 * ALREADY in flight with no data yet — query-core coalesces that invalidation
 * instead of restarting it, so `fetchVaultTreeFresh` detects it out-of-band and
 * re-fetches. Bump BEFORE invalidating, so a fetch that completes between the
 * two lines still sees the new generation.
 */
export function invalidateVaultTree(qc: QueryClient, vaultId: string | null | undefined): void {
	treeInvalidationGen++;
	qc.invalidateQueries({ queryKey: ["vault-tree", vaultId] });
	// Every caller of this is a note/folder create, delete, or move — exactly
	// the mutations that change how many notes exist, and therefore whether the
	// user is over their index cap. Riding the tree invalidation rather than
	// hand-listing the mutations means a future write path cannot forget it.
	qc.invalidateQueries({ queryKey: ["index_status"] });
}

export function useVaultTree() {
	const vaultId = useActiveVaultId();
	// `enabled`: ungated, a deep link landing before the bootstrap reconcile
	// (see reconcileActiveVault) would fetch — and server-side decrypt — the
	// wrong vault's entire inventory under a key nothing later reads.
	return useQuery({ ...vaultTreeQueryOptions(vaultId), enabled: Boolean(vaultId) });
}

export function useNote(id: string | null) {
	const vaultId = useActiveVaultId();
	const qc = useQueryClient();
	const placeholder = useCallback(
		(prev: Note | undefined) => prev ?? noteFromVaultTree(qc, vaultId, id),
		[qc, vaultId, id],
	);
	return useQuery({
		queryKey: ["note", vaultId, id],
		queryFn: () => fetchNoteById(id ?? ""),
		enabled: id !== null,
		// Two different blank-outs, one setting.
		//
		// Navigating: the key changes, which without a placeholder drops to
		// no-data → NotePage's `isLoading` branch → the whole pane (header,
		// title, editor) replaced by a spinner for the length of one request.
		// Previous data wins here — swapping in the tree stub instead would put
		// the incoming note's chrome over the outgoing note's live document,
		// which is exactly the invariant NotePage exists to hold.
		//
		// First open of a session: there IS no previous note, so the above gave
		// nothing and the spinner won. The vault tree already knows this note's
		// id, path and title, so the chrome can render immediately and only the
		// body waits (#1317 — measured as a full-pane loading circle).
		// useCallback, not an inline arrow: query-core reuses the previous
		// placeholder only when this option is reference-equal to last render's,
		// so a fresh arrow re-ran the whole-vault `notes.find` scan plus a
		// deep-equal on EVERY render for the duration of the fetch — an O(notes)
		// walk on the exact frame budget this is meant to protect.
		placeholderData: placeholder,
	});
}

export interface Backlink {
	source_note_id: string;
	source_path: string;
	source_title: string | null;
	alias: string | null;
	anchor: string | null;
}

// Backlinks panel (right rail). Task 1 stores the forward edges on the note
// payload (`links`); this is the reverse lookup, so it needs its own request.
export function useBacklinks(noteId: string | null) {
	const vaultId = useActiveVaultId();
	return useQuery({
		queryKey: ["backlinks", vaultId, noteId],
		queryFn: () => api.get<{ backlinks: Backlink[] }>(`/notes/by-id/${noteId}/backlinks`),
		enabled: noteId !== null,
		// The API returns one row per link EDGE, so a source note linking twice
		// (e.g. plain + aliased) appears twice. The panel renders one row per
		// source note, so dedupe here (keep the first edge per source).
		select: (d) => {
			const seen = new Set<string>();
			return d.backlinks.filter((b) => {
				if (seen.has(b.source_note_id)) {
					return false;
				}
				seen.add(b.source_note_id);
				return true;
			});
		},
	});
}

export function useUpdateNote() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation({
		mutationFn: ({ path, content, version }: { path: string; content: string; version?: number }) =>
			api.post<{ note: Note }>("/notes", {
				path,
				content,
				version,
				mtime: Date.now() / 1000,
			}),
		onSuccess: (data) => {
			// The note cache is keyed by id (`['note', vaultId, id]`), not
			// path. Invalidate the specific id when the server returns it,
			// and refresh folder listings so the title/mtime stay current.
			const id = data?.note?.id;
			if (id !== undefined) {
				qc.invalidateQueries({ queryKey: ["note", vaultId, id] });
			}
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
			// This edit may have changed the note's forward links, which changes
			// what OTHER notes' backlinks panels show -- same reasoning as the
			// note_changed handler in api/channel.ts.
			qc.invalidateQueries({ queryKey: ["backlinks"] });
		},
	});
}

export function useCreateNote() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	const navigate = useNavigate();

	// Filenames already used in `folder`, ignoring our own optimistic
	// placeholders so a row we just inserted doesn't bump the name the server
	// ends up picking.
	const takenNames = (tree: VaultTree | undefined, folder: string) =>
		new Set(
			(tree?.notes ?? [])
				.filter((n) => !n.pending && folderOf(n.path) === folder)
				.map((n) => baseOf(n.path)),
		);

	return useMutation<
		{ path: string; id: string },
		ApiError,
		// `name` defaults to "Untitled.md" (the sidebar "New note" button) — the
		// unresolved-wikilink "create this note" affordance passes the target's
		// derived filename instead. Either way collideBump still guards a race.
		{ folder: string; id: string; name?: string; renameOnArrive?: boolean },
		CreateNoteContext | undefined
	>({
		mutationFn: async ({ folder, id, name: desiredName = "Untitled.md" }) => {
			const taken = takenNames(qc.getQueryData<VaultTree>(["vault-tree", vaultId]), folder);

			const MAX_RACES = 5;
			for (let attempt = 0; attempt < MAX_RACES; attempt++) {
				const name = collideBump(taken, desiredName, { cap: 1000 });
				const path = joinPath(folder, name);
				try {
					// crdt_create genesis over the live channel (replaces POST /notes);
					// the ok reply echoes our minted note_id. The id is stable across
					// retries — a collision rejects the PATH, never the id, and the
					// optimistic row is already rendering under it.
					await crdtCreateNote(id, path);
					return { path, id };
				} catch (err) {
					// The path is already owned (unique-constraint create_failed) or was
					// just deleted (delete-wins window) — bump the name and retry, the
					// CRDT twin of the old 409 loop. Cap/rate/disconnect propagate.
					if (
						err instanceof CrdtOpError &&
						(err.reason === "create_failed" || err.reason === "recently_deleted")
					) {
						taken.add(name);
						continue;
					}
					throw err;
				}
			}
			throw new ApiError(500, "useCreateNote: exceeded race retries");
		},
		// Drop a pending row into the tree so the note appears instantly
		// (on-disk feel), then settle it to the server's path on success.
		onMutate: async ({ folder, id, name: desiredName = "Untitled.md" }) => {
			const tree = await snapshotTree(qc, vaultId);
			if (!tree) {
				return;
			}
			const now = new Date().toISOString();
			const patched = patchTree(qc, vaultId, (t) =>
				upsertNote(t, {
					// The id we're about to send, not a throwaway: the row is
					// addressable the moment it appears, so clicking it before the ack
					// opens the right note instead of a dead `optimistic-…` route.
					id,
					path: joinPath(folder, collideBump(takenNames(tree, folder), desiredName, { cap: 1000 })),
					pending: true,
					created_at: now,
					updated_at: now,
				}),
			);
			return { tree, patched, id };
		},
		onSuccess: ({ id, path }, vars) => {
			// Settle the pending row onto the confirmed path before the refetch
			// lands, so the row never flashes out and back.
			patchTree(qc, vaultId, (t) => {
				const row = t.notes.find((n) => n.id === id);
				return row ? upsertNote(t, { ...row, path, pending: false }) : t;
			});
			invalidateVaultTree(qc, vaultId);
			// Keep the path-keyed list fresh for the dashboard folder-browse view.
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId, vars.folder] });
			// vaultId is already resolved in this mutation's closure; look up its
			// slug from the cache rather than re-deriving it (a hook is
			// unavailable here, since this runs inside a mutation callback).
			// getQueryData bypasses useVaults's `select`, so the raw cache entry
			// is still the wire shape ({ vaults }), not the post-select array.
			const slug = qc
				.getQueryData<{ vaults: Vault[] }>(["vaults"])
				?.vaults?.find((v) => v.id === vaultId)?.slug;
			// `justCreated` puts the note page's inline title straight into rename
			// mode with "Untitled" selected. Carried as navigation state rather than
			// a context because it must fire exactly once, and router state is
			// already scoped to a single navigation. Both creation entry points (the
			// tree's context menu and the sidebar button) route through here.
			// A wikilink create already knows the name — the link supplied it — so
			// it opts out and the note just opens. Defaults on for the tree and
			// sidebar buttons, which create "Untitled".
			navigate(noteHref(slug, id), {
				state: { justCreated: vars.renameOnArrive !== false },
			});
		},
		onError: (err, _vars, ctx) => {
			restoreTree(qc, vaultId, ctx?.tree, ctx?.patched);
			if (err instanceof CrdtOpError && err.reason === "notes_cap_reached") {
				toast.error("You've hit your note limit — upgrade to add more.");
			} else if (err instanceof CrdtOpError && err.reason === "disconnected") {
				toast.error("Reconnecting — can't create notes while offline.");
			} else {
				toast.error("Couldn't create the note. Try again.");
			}
		},
	});
}

export function useCreateFolder() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();

	return useMutation<{ folder: string }, ApiError, { parent: string }>({
		mutationFn: async ({ parent }) => {
			const tree = qc.getQueryData<VaultTree>(["vault-tree", vaultId]);
			const existingFolders = tree?.folders.map((f) => f.name) ?? [];

			// Restrict to direct children of the parent — siblings only.
			const prefix = parent ? `${parent}/` : "";
			const childNames = new Set(
				existingFolders
					.filter((f) => (parent === "" ? !f.includes("/") : f.startsWith(prefix)))
					.map((f) => (parent === "" ? f : f.slice(prefix.length)))
					.map((f) => f.split("/")[0] ?? f),
			);

			const MAX_RACES = 5;
			for (let attempt = 0; attempt < MAX_RACES; attempt++) {
				const name = collideBump(childNames, "untitled", { cap: 1000 });
				const folder = parent ? `${parent}/${name}` : name;
				try {
					await api.post<{ folder: { name: string; count: number } }>("/folders", { folder });
					return { folder };
				} catch (err) {
					if (err instanceof ApiError && err.status === 409) {
						childNames.add(name);
						continue;
					}
					throw err;
				}
			}
			throw new ApiError(500, "useCreateFolder: exceeded race retries");
		},
		onSuccess: () => {
			invalidateVaultTree(qc, vaultId);
		},
		onError: (err) => {
			if (err instanceof ApiError && err.status === 422) {
				toast.error("That folder name isn't allowed.");
			} else if (err instanceof ApiError && err.status === 403) {
				toast.error("You don't have permission to create folders here.");
			} else {
				toast.error("Couldn't create the folder. Try again.");
			}
		},
	});
}

export interface SearchFilters {
	type?: string;
	folder?: string;
	tags?: string[];
	createdAfter?: string;
	createdBefore?: string;
	updatedAfter?: string;
	updatedBefore?: string;
}

export function useSearch(query: string, filters: SearchFilters = {}) {
	const vaultId = useActiveVaultId();
	return useQuery({
		queryKey: ["search", vaultId, query, filters],
		// Each search costs a Voyage embedding + Qdrant round trip server-side:
		// abort superseded requests, and keep the previous results rendered
		// while the next key loads so the panel doesn't flicker empty.
		queryFn: ({ signal }) =>
			api.post<{ results: SearchResult[] }>(
				"/search",
				{
					query,
					limit: 20,
					...(filters.type ? { type: filters.type } : {}),
					...(filters.folder ? { folder: filters.folder } : {}),
					...(filters.tags && filters.tags.length > 0 ? { tags: filters.tags } : {}),
					...(filters.createdAfter ? { created_after: filters.createdAfter } : {}),
					...(filters.createdBefore ? { created_before: filters.createdBefore } : {}),
					...(filters.updatedAfter ? { updated_after: filters.updatedAfter } : {}),
					...(filters.updatedBefore ? { updated_before: filters.updatedBefore } : {}),
				},
				{ signal },
			),
		select: (data) => data.results,
		enabled: query.length > 0,
		placeholderData: keepPreviousData,
	});
}

export function useTags() {
	const vaultId = useActiveVaultId();
	return useQuery({
		queryKey: ["tags", vaultId],
		// TagsController sends `[{name}]`, NOT bare strings. This was declared as
		// `string[]` — an unchecked assertion, so TypeScript believed it and the
		// first consumer to render a tag got an object. The hook keeps the useful
		// contract (string[]) and now actually produces it.
		queryFn: () => api.get<{ tags: Array<{ name: string }> }>("/tags"),
		select: (data) => data.tags.map((t) => t.name),
		// Same reasoning as useFolders: with no vault to scope the read to, a deep
		// link arriving before the bootstrap reconcile would fetch some other
		// vault's tag inventory.
		enabled: Boolean(vaultId),
	});
}

/**
 * The OKF `type` values actually present in the vault, for the search filter's
 * suggestions. Server-normalised (NFKC + lowercase) so the list matches the
 * filter's own buckets — `Playbook` and `playbook` arrive as one entry.
 */
export function useTypes() {
	const vaultId = useActiveVaultId();
	return useQuery({
		queryKey: ["types", vaultId],
		queryFn: () => api.get<{ types: Array<{ name: string }> }>("/types"),
		select: (data) => data.types.map((t) => t.name),
		enabled: Boolean(vaultId),
	});
}

export function useMe() {
	return useQuery({
		queryKey: ["me"],
		queryFn: () => api.get<{ user: User }>("/me"),
		select: (data) => data.user,
	});
}

export function useUpdateProfile() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (body: { display_name: string | null }) => api.patch<{ user: User }>("/me", body),
		onSuccess: (data) => {
			qc.setQueryData(["me"], data);
		},
	});
}

export function useDeleteSelf() {
	return useMutation<void, Error, { password: string }>({
		mutationFn: async ({ password }) => {
			// Body, never the query string: a password in a URL lands in Phoenix's
			// and the load balancer's access logs, in browser history, and in
			// Sentry's fetch breadcrumb — none of which the user consented to
			// when they typed it into a confirm dialog.
			await api.del<void>("/me", { password });
		},
	});
}

// Billing types
export interface BillingStatus {
	tier: "free" | "none" | "trial" | "starter" | "pro";
	active: boolean;
	trial_days_remaining: number;
	subscription: {
		status: string;
		tier: string;
		current_period_end: string;
	} | null;
	caps: {
		obsidian_connections: number | null;
		mcp_connections: number | null;
		api_write_enabled: boolean;
		vaults: number | null;
	};
	// Bundled into /billing/status so the proactive cap UI (on /link and
	// /oauth/consent) can decide atCap from a single fetch — no separate
	// /connections call just to count.
	current_connections: {
		obsidian: number;
		mcp: number;
	};
	// Hours remaining on the Free-tier device-swap cooldown after a recent
	// device revoke; `null` when no cooldown is in effect. Lets /link render
	// a cooldown banner + disable Authorize BEFORE the user trips the 402.
	device_swap_cooldown_remaining_hours: number | null;
}

// Billing hooks

export function useBillingStatus() {
	return useQuery({
		queryKey: ["billing", "status"],
		queryFn: () => api.get<BillingStatus>("/billing/status"),
		// Seeded fresh by useAppBootstrap on first load; mutations that change
		// billing invalidate this key explicitly, so a short staleTime just
		// suppresses a redundant refetch-on-mount of the seeded payload.
		staleTime: 60_000,
	});
}

export interface BillingConfig {
	client_token: string;
	environment: "sandbox" | "production";
	price_ids: {
		starter: { monthly: string; annual: string };
		pro: { monthly: string; annual: string };
	};
	customer_email: string;
	custom_data: {
		user_id: string;
	};
	// Maximum number of active vaults the user may have, or null for unlimited.
	vaults_cap: number | null;
}

export type BillingCadence = "monthly" | "annual";

export function useBillingConfig() {
	return useQuery({
		queryKey: ["billing", "config"],
		queryFn: () => api.get<BillingConfig>("/billing/config"),
		staleTime: Number.POSITIVE_INFINITY,
	});
}

export interface SubscriptionDetail {
	next_billed_at: string | null;
	amount: string | null;
	currency: string | null;
	billing_cycle: { interval: string; frequency: number } | null;
	scheduled_change: { action: string; effective_at: string } | null;
}

export interface PaymentMethod {
	type: string | null;
	card_brand: string | null;
	last4: string | null;
	exp_month: number | null;
	exp_year: number | null;
}

export interface BillingTransaction {
	id: string;
	billed_at: string | null;
	amount: string | null;
	currency: string | null;
	status: string;
	invoice_id: string | null;
}

export interface BillingHistory {
	payment_method: PaymentMethod | null;
	transactions: BillingTransaction[];
}

// Live read-through endpoints — only meaningful for users with a Paddle
// subscription (they 404 otherwise), so callers gate with `enabled`.
export function useBillingSubscriptionDetail(enabled: boolean) {
	return useQuery({
		queryKey: ["billing", "subscription"],
		queryFn: () => api.get<SubscriptionDetail>("/billing/subscription"),
		enabled,
	});
}

export function useBillingHistory(enabled: boolean) {
	return useQuery({
		queryKey: ["billing", "transactions"],
		queryFn: () => api.get<BillingHistory>("/billing/transactions"),
		enabled,
	});
}

// Onboarding types

export type OnboardingAction =
	| "first_vault_created"
	| "plugin_connected"
	| "ai_connected"
	| `dismissed:${string}`;

export interface OnboardingStatus {
	enabled: boolean;
	terms_ok?: boolean;
	subscription_ok?: boolean;
	profile_complete?: boolean;
	// Echoed back once `set_profile/2` has run — drives the personalized
	// setup cards on the dashboard. Absent until the questionnaire is done.
	profile?: OnboardingProfile;
	// True when at least one non-deleted vault exists. The fresh-start
	// onboarding path (uses_obsidian=false) gates `next_step: "vault"` on
	// this; Obsidian users short-circuit past the gate (plugin creates the
	// vault on first OAuth sign-in).
	has_vault?: boolean;
	current_tos_version?: string;
	current_privacy_version?: string;
	next_step: OnboardingStep | "done";
	// Full intended step chain for THIS account at this moment. Self-host
	// returns ["tools","vault"]; hosted returns ["agreement","billing",
	// "tools","vault"]. `:tools` collects the FTUX tool checkboxes; `:vault`
	// owns the obsidian/fresh source pick + first-vault creation. The
	// frontend uses this for "Step X of N" and to reject manual nav to a
	// step not in the chain (e.g. /onboard/agreement on self-host).
	steps: OnboardingStep[];
	// Post-wizard milestone log driving the persistent dashboard checklist.
	actions: OnboardingAction[];
	// Live vault count for checklist gating.
	vault_count: number;
}

export type OnboardingStep = "agreement" | "billing" | "tools" | "vault";

// Partial mid-flow: the `:tools` step POSTs `tools` first, the `:vault`
// step POSTs `uses_obsidian` after. `completed_at` only stamps once both
// have landed — until then, treat absent fields as "user hasn't answered
// that screen yet."
export interface OnboardingProfile {
	uses_obsidian?: boolean;
	tools?: string[];
	completed_at?: string;
}

// Onboarding hooks

// `enabled: false` lets a consumer that mounts alongside useAppBootstrap (the
// onboarding gate) wait for the bootstrap seed instead of racing it with its
// own /onboarding/status fetch.
export function useOnboardingStatus(opts: { enabled?: boolean } = {}) {
	return useQuery({
		queryKey: ["onboarding", "status"],
		queryFn: () => api.get<OnboardingStatus>("/onboarding/status"),
		staleTime: Number.POSITIVE_INFINITY,
		refetchOnWindowFocus: true,
		enabled: opts.enabled ?? true,
	});
}

export function useRecordOnboardingAction() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (action: OnboardingAction) =>
			api.post<{ status: string }>("/onboarding/actions", { action }),
		onSuccess: () => qc.invalidateQueries({ queryKey: ["onboarding", "status"] }),
		retry: 3,
	});
}

// ── Bootstrap ──────────────────────────────────────────────────────────────
//
// One round-trip on first load that returns onboarding + capabilities + vaults
// (+ billing when enabled), replacing the serial onboarding/billing/vaults
// fan-out the app used to make before becoming usable. See
// docs/context/spa-state-injection.md for why this is a fetch (the SaaS HTML is
// served by Cloudflare and can't inject per-user post-auth state at first paint).

// Resolved entitlement matrix. Every LimitKeys key: an integer cap, a boolean
// feature flag, or null (no cap / unlimited). Advisory for UX gating — the
// server still enforces every limit authoritatively.
export interface Capabilities {
	tier: "free" | "starter" | "pro";
	limits: Record<string, number | boolean | null>;
}

// Live note counters. Deliberately NOT part of `capabilities`: that matrix is
// ETS-cached for 24h server-side, and these move every time the user writes a
// note. `indexed` is min(total, cap) — the cap is the contract; how far the
// index queue has drained is an implementation detail we don't surface.
//
// Both are 0 for an uncapped tier: the server skips the whole-vault count
// rather than pay for a number that tier never renders. Read them only as the
// `indexed < total` question, never as "how many notes exist".
export interface IndexStatus {
	indexed: number;
	total: number;
}

export interface BootstrapPayload {
	onboarding: OnboardingStatus;
	capabilities: Capabilities;
	index_status: IndexStatus;
	vaults: { vaults: Vault[] };
	// Present only when billing is enabled (SaaS); absent on self-host.
	billing?: BillingStatus;
}

export function useCapabilities() {
	return useQuery({
		queryKey: ["capabilities"],
		// Normally read straight from the cache seeded by useAppBootstrap (staleTime
		// Infinity → no fetch). The queryFn is a fallback for any consumer that
		// mounts before the gate's bootstrap seed lands.
		queryFn: () => api.get<BootstrapPayload>("/bootstrap").then((b) => b.capabilities),
		staleTime: Number.POSITIVE_INFINITY,
	});
}

/**
 * Seeded by useAppBootstrap, then kept current on its own — see the staleTime
 * note below for why it cannot stay frozen at the seed.
 *
 * Unlike useCapabilities the fallback is not /bootstrap but /index-status,
 * which returns these two counters alone: a consumer that mounts before the
 * seed lands should not pay for the whole first-load payload to render one
 * advisory line ("Searching 2,000 of 4,312 notes").
 */
export function useIndexStatus() {
	return useQuery<IndexStatus>({
		queryKey: ["index_status"],
		queryFn: () => api.get<IndexStatus>("/index-status"),
		// Seeded by /bootstrap, so the first render costs no request. But these
		// counters move as the user writes and deletes notes, and they drive the
		// only signal that stops a note past the cap returning nothing from
		// reading as broken search — frozen at page load, a user who crossed the
		// cap mid-session saw no banner until a full reload. A finite staleTime
		// plus invalidation on create/delete keeps it honest; the refetch is
		// cheap, and free for uncapped users (counts/1 skips the aggregate).
		staleTime: 60_000,
	});
}

/**
 * Fetches the consolidated first-load payload and seeds the granular query
 * caches (onboarding, billing, vaults, capabilities) so the hooks that read
 * those keys resolve from cache instead of issuing their own requests. Mount
 * this at the top of the authenticated tree (the onboarding gate) so the seed
 * lands before any vault-scoped view mounts.
 */
export function useAppBootstrap() {
	const qc = useQueryClient();
	return useQuery({
		queryKey: ["bootstrap"],
		queryFn: async () => {
			const data = await api.get<BootstrapPayload>("/bootstrap");
			qc.setQueryData(["onboarding", "status"], data.onboarding);
			qc.setQueryData(["capabilities"], data.capabilities);
			qc.setQueryData(["index_status"], data.index_status);
			qc.setQueryData(["vaults"], data.vaults);
			// Runs here, not in an effect: parent effects fire AFTER their
			// children's, so a gate-level effect would land one render too late and
			// the sidebar's folder/attachment queries would already have gone out
			// under a dead vault id. See reconcileActiveVault.
			reconcileActiveVault(data.vaults.vaults);
			if (data.billing) {
				qc.setQueryData(["billing", "status"], data.billing);
			}
			return data;
		},
		staleTime: Number.POSITIVE_INFINITY,
	});
}

export function useAcceptTerms() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (body: {
			tos_version: string;
			tos_hash: string;
			privacy_version: string;
			privacy_hash: string;
		}) => api.post<{ version: string; accepted_at: string }>("/onboarding/accept-terms", body),
		// `await` is load-bearing: callers (agreement-page) navigate to /onboard
		// immediately after the mutation resolves, and OnboardRedirect reads cached
		// status to pick the next step. Without awaiting the refetch, the stale
		// `next_step: 'agreement'` bounces the user back to the same page and
		// they're forced to accept twice. invalidateQueries returns a Promise that
		// settles when active queries have refetched — await it.
		onSuccess: async () => {
			await qc.invalidateQueries({ queryKey: ["onboarding", "status"] });
		},
	});
}

// Partial body — the `:tools` screen POSTs `{ tools }`, the `:vault` screen
// POSTs `{ uses_obsidian }`. Either field may be present (or both, on a
// one-shot completion). Backend `set_profile/2` merges into the JSONB
// column and stamps `completed_at` once both halves have landed.
export function useSetOnboardingProfile() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (body: { uses_obsidian?: boolean; tools?: string[] }) =>
			api.patch<OnboardingProfile>("/onboarding/profile", body),
		// AWAIT the invalidation so mutateAsync resolves only after
		// ['onboarding','status'] has refetched. Without the await,
		// OnboardingGate reads the still-cached next_step (e.g. "tools")
		// immediately after navigate and bounces back here.
		onSuccess: async () => {
			await qc.invalidateQueries({ queryKey: ["onboarding", "status"] });
		},
	});
}

// API key result shape — created by useCreatePat below; kept as a named
// type because the reveal modal in settings/connections-page.tsx imports it.

export interface CreatedApiKey {
	id: string;
	name: string;
	key: string;
}

// ── Connections ─────────────────────────────────────────────

export type ConnectionKind = "obsidian" | "mcp" | "pat";

export interface Connection {
	kind: ConnectionKind;
	client_id: string | null;
	/** The grant lineage this row IS. One OAuth client can hold several grants
	 *  over different vault sets, each rendered as its own row, so `client_id`
	 *  alone cannot address the row the user clicked. Null for PATs. */
	family_id: string | null;
	key_id: string | null;
	name: string | null;
	/** The user's own name for this connection. `name` falls back through the
	 *  client's self-reported and catalog names; this is only ever theirs. */
	label: string | null;
	software_id: string | null;
	software_version: string | null;
	verified: boolean;
	logo: string | null;
	slug: string | null;
	/** Vaults this connection may reach. Null means all vaults. */
	vault_ids: string[] | null;
	/** Positional against `vault_ids`. An entry is null when the vault is gone
	 *  or outside the caller's own grant scope. */
	vault_names: (string | null)[] | null;
	scope: string | null;
	last_used_at: string | null;
	connected_at: string | null;
	first_user_agent: string | null;
	first_ip: string | null;
	/** Where this grant's authorization code was actually delivered. This, not
	 *  `redirect_uris`, decides `verified`. Null for non-OAuth connections and
	 *  for grants issued before it was recorded. */
	redirect_uri: string | null;
	/** Every redirect the client registered. Informational only: a client may
	 *  register several and pick one per authorization, so a vendor host here
	 *  proves nothing about this grant. */
	redirect_uris: string[];
	/** CIMD metadata-document URL. Present only for clients that published one;
	 *  it is the client's public identifier and the reason it can be verified
	 *  despite redirecting to loopback. */
	cimd_url: string | null;
}

export interface CapErrorBody {
	error: "connection_cap_reached";
	kind: "obsidian" | "mcp";
	current: number;
	limit: number;
	upgrade_url: string;
}

export interface PatDisabledErrorBody {
	error: "pat_disabled_on_free";
	upgrade_url: string;
}

export function useConnections(opts?: { enabled?: boolean }) {
	return useQuery({
		queryKey: ["connections"],
		queryFn: () => api.get<Connection[]>("/connections"),
		enabled: opts?.enabled ?? true,
	});
}

export function useCreatePat() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (name: string) =>
			api.post<{ key: string; id: string; name: string }>("/connections/pat", { name }),
		onSuccess: () => {
			qc.invalidateQueries({ queryKey: ["connections"] });
		},
	});
}

/** Revokes one grant when `familyId` is given, otherwise the whole client.
 *  The connections list passes it so Disconnect kills only the row clicked;
 *  the cap-swap flows (ExistingConnectionsPanel, the OAuth consent page) call
 *  `api.del` without it on purpose — the cap counts clients, not grants, so a
 *  per-grant revoke would not free a slot. */
export function useRevokeOauthConnection() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: ({ clientId, familyId }: { clientId: string; familyId?: string | null }) =>
			api.del(
				familyId
					? `/connections/oauth/${clientId}?family_id=${encodeURIComponent(familyId)}`
					: `/connections/oauth/${clientId}`,
			),
		onSuccess: () => qc.invalidateQueries({ queryKey: ["connections"] }),
	});
}

export function useRevokeDeviceConnection() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (familyId: string) => api.del(`/connections/device/${familyId}`),
		onSuccess: () => qc.invalidateQueries({ queryKey: ["connections"] }),
	});
}

export function useRevokePat() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (id: string) => api.del(`/connections/pat/${id}`),
		onSuccess: () => {
			qc.invalidateQueries({ queryKey: ["connections"] });
		},
	});
}

// Vault types

export interface Vault {
	id: string;
	name: string;
	description: string | null;
	slug: string;
	is_default: boolean;
	created_at: string;
	deleted_at?: string | null;
	purge_at?: string | null;
	note_count?: number;
	attachment_count?: number;
}

// Vault hooks

export function useVaults() {
	return useQuery({
		queryKey: ["vaults"],
		queryFn: async () => {
			const data = await api.get<{ vaults: Vault[] }>("/vaults");
			// Second reconcile point, and the one that covers in-session death of
			// the active vault: deleting/purging a vault only invalidates this key,
			// so without this the store would keep pointing at the vault the user
			// just deleted (404ing every request) until a full reload.
			reconcileActiveVault(data.vaults);
			return data;
		},
		select: (data) => data.vaults,
		// Seeded fresh by useAppBootstrap on first load; vault mutations invalidate
		// this key explicitly, so a short staleTime just suppresses the redundant
		// refetch-on-mount of the seeded list.
		staleTime: 60_000,
	});
}

export function useEncryptVault() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (id: string) => api.post<{ vault: Vault }>(`/vaults/${id}/encrypt`),
		onSuccess: () => {
			qc.invalidateQueries({ queryKey: ["vaults"] });
			qc.invalidateQueries({ queryKey: ["encryption-progress"] });
		},
	});
}

export function useDeletedVaults() {
	return useQuery({
		queryKey: ["vaults", "deleted"],
		queryFn: () => api.get<{ vaults: Vault[] }>("/vaults?deleted=true"),
		select: (data) => data.vaults,
	});
}

// Vault count is an onboarding input: the backend answers `next_step: :vault`
// for an account that owns none, and OnboardingGate redirects there. That
// verdict is computed once, at bootstrap — so a user who deletes their LAST
// vault mid-session would otherwise sit in a shell with nothing to show and no
// route out, every request 404ing on `no_default_vault` until a manual reload.
// Invalidating ["bootstrap"] alongside ["vaults"] re-runs the gate.
export function useDeleteVault() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (id: string) => api.del<{ deleted: boolean }>(`/vaults/${id}`),
		onSuccess: () =>
			Promise.all([
				qc.invalidateQueries({ queryKey: ["vaults"] }),
				qc.invalidateQueries({ queryKey: ["bootstrap"] }),
			]),
	});
}

export function useRestoreVault() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (id: string) => api.post<{ vault: Vault }>(`/vaults/${id}/restore`),
		// Restoring the only vault has to flip the gate back the other way
		// (`:vault` -> `:done`), or the user is stuck on the wizard step.
		onSuccess: () =>
			Promise.all([
				qc.invalidateQueries({ queryKey: ["vaults"] }),
				qc.invalidateQueries({ queryKey: ["bootstrap"] }),
			]),
	});
}

export function usePurgeVault() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (id: string) => api.post<{ purged: boolean }>(`/vaults/${id}/purge`),
		onSuccess: () =>
			Promise.all([
				qc.invalidateQueries({ queryKey: ["vaults"] }),
				qc.invalidateQueries({ queryKey: ["bootstrap"] }),
			]),
	});
}

export function useUpdateVault() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: ({
			id,
			...attrs
		}: {
			id: string;
			name?: string;
			description?: string;
			is_default?: boolean;
		}) => api.patch<{ vault: Vault }>(`/vaults/${id}`, attrs),
		onSuccess: () => qc.invalidateQueries({ queryKey: ["vaults"] }),
	});
}

export function useCreateVault() {
	const qc = useQueryClient();
	return useMutation({
		// POST /vaults/register is the only create endpoint, and it is
		// idempotent by client_id: a retry after a timeout or a double submit
		// resolves to the vault the first attempt already created instead of
		// minting a second one. Callers must therefore hold `client_id` STABLE
		// across retries of one user intent — mint it when the form mounts, not
		// per submit, or the idempotency is a no-op. Responds with the vault
		// flat (plus `status`), not wrapped in `{ vault }`.
		mutationFn: (attrs: { name: string; client_id: string }) =>
			api.post<Vault>("/vaults/register", attrs),
		onSuccess: () => {
			qc.invalidateQueries({ queryKey: ["vaults"] });
			// Backend records `first_vault_created` in Vaults.register_vault/4;
			// refresh /status so the onboarding checklist ticks immediately.
			qc.invalidateQueries({ queryKey: ["onboarding", "status"] });
		},
	});
}

// Inline billing mutations replacing the portal redirect — each invalidates
// /billing/status + /billing/subscription so the StatusCard reflects the
// new scheduled change immediately, before webhook sync catches up.

/**
 * Invalidate every cache derived from the user's subscription state — the
 * volatile billing slices AND the cached capability matrix (`['capabilities']`,
 * the tier+limits map seeded by bootstrap). Call after ANY subscription change
 * (checkout completed, activation push, plan change, cancel, reverse-cancel) so
 * the tier badge, caps, plan-change "current" highlight, and free-tier gates
 * all refresh together. Missing one key here is how an upgrade leaves the UI
 * stuck on the old tier until a manual refresh (#603). Returns a promise so
 * callers that need fresh data before navigating can await it.
 */
export function invalidateBillingState(qc: QueryClient) {
	return Promise.all([
		qc.invalidateQueries({ queryKey: ["billing", "status"] }),
		qc.invalidateQueries({ queryKey: ["billing", "subscription"] }),
		qc.invalidateQueries({ queryKey: ["billing", "transactions"] }),
		qc.invalidateQueries({ queryKey: ["capabilities"] }),
	]);
}

export function useCancelSubscription() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: () => api.post<Record<string, unknown>>("/billing/cancel-subscription"),
		onSuccess: () => invalidateBillingState(qc),
	});
}

export function useReverseCancel() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: () => api.post<Record<string, unknown>>("/billing/reverse-cancel"),
		onSuccess: () => invalidateBillingState(qc),
	});
}

export interface PlanChangePreview {
	old_total: number;
	new_total: number;
	immediate_charge_or_credit: number;
	next_billed_at: string;
}

export function usePlanChangePreview(targetPriceId: string | null) {
	return useQuery({
		queryKey: ["billing", "plan-change", "preview", targetPriceId],
		enabled: targetPriceId !== null,
		queryFn: () =>
			api.post<PlanChangePreview>("/billing/plan-change/preview", {
				target_price_id: targetPriceId,
			}),
		// Preview hits Paddle. Without these, every window focus/refocus
		// (alt-tab back to the picker tab) re-POSTs to Paddle. The data
		// is stable for the lifetime of the picker session — proration
		// math only changes when the user picks a different target or
		// a webhook flips their subscription (both invalidate the key).
		staleTime: 5 * 60_000,
		refetchOnWindowFocus: false,
	});
}

export function useConfirmPlanChange() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (targetPriceId: string) =>
			api.post<Record<string, unknown>>("/billing/plan-change/confirm", {
				target_price_id: targetPriceId,
			}),
		onSuccess: () => invalidateBillingState(qc),
	});
}

// ── Tree mutations (rename / delete / duplicate) ─────────────
//
// Folder/note rename + delete on the tree. Rename endpoints return 409
// on target-exists (collision) and 404 if the source is missing — both
// surface as ApiError to the caller via api.post / api.del.
//
// Each mutation runs optimistically: `onMutate` snapshots the affected
// caches, applies the change locally so the UI updates synchronously,
// and stashes the snapshot in the mutation context. `onError` restores
// the snapshot and toasts the failure. `onSettled` invalidates the
// affected query families so the server stays the source of truth and
// out-of-band changes (Phoenix channel push, other-tab edits) get
// reconciled.

export function useRenameNote() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<
		{ renamed: boolean; old_path: string; new_path: string },
		CrdtOpError,
		{ id: string; old_path: string; new_path: string },
		NoteBodyContext
	>({
		// Rename/move = crdt_create for a KNOWN live id at a new FREE path — the
		// backend relocates the row in place (rename-as-move, notes.ex Phase E2),
		// keeping the note_id + content. A path OCCUPIED by a different note comes
		// back as create_failed. Replaces POST /notes/rename.
		mutationFn: async ({ id, old_path, new_path }) => {
			await crdtCreateNote(id, new_path);
			return { renamed: true, old_path, new_path };
		},
		onMutate: async ({ id, new_path }) => {
			const tree = await snapshotTree(qc, vaultId);
			const noteKey = ["note", vaultId, id] as const;
			await qc.cancelQueries({ queryKey: noteKey });
			const prevNote = qc.getQueryData<Note>(noteKey);

			const patched = patchTree(qc, vaultId, (t) => renameNotes(t, [{ id, newPath: new_path }]));

			// Re-path the note-body cache too, so an open editor's header flips the
			// moment the user commits instead of lagging until the settle refetch.
			// Safe because note-page.tsx keys its CRDT doc on `note.id` (stable
			// across a rename) and reads `path` only for display + the `.md` gate.
			if (prevNote) {
				qc.setQueryData<Note>(noteKey, {
					...prevNote,
					path: new_path,
					folder: folderOf(new_path),
				});
			}
			return { tree, patched, noteId: id, prevNote };
		},
		onError: (err, _vars, ctx) => {
			if (!ctx) {
				return;
			}
			restoreTree(qc, vaultId, ctx.tree, ctx.patched);
			// Undo the optimistic re-path so a refused rename can't leave the
			// header showing a name the server never accepted.
			if (ctx.prevNote) {
				qc.setQueryData<Note>(["note", vaultId, ctx.noteId], ctx.prevNote);
			}
			renameErrorToast(err, "file");
		},
		onSettled: () => {
			invalidateVaultTree(qc, vaultId);
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
			qc.invalidateQueries({ queryKey: ["note", vaultId] });
		},
	});
}

export function useRenameFolder() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<
		{ renamed: boolean; old_path: string; new_path: string; count: number },
		ApiError,
		{ old_path: string; new_path: string },
		TreeContext
	>({
		mutationFn: (vars) =>
			api.post<{
				renamed: boolean;
				old_path: string;
				new_path: string;
				count: number;
			}>("/folders/rename", vars),
		// Exact, not coarse. The old patch rewrote folder names and then DROPPED
		// every cached note list under the old prefix, because re-pathing notes
		// across per-folder caches was too fiddly to get right. One tree makes the
		// descendant re-path a single pass, so nothing has to be thrown away and
		// refetched on next expand.
		onMutate: async ({ old_path, new_path }) => {
			const tree = await snapshotTree(qc, vaultId);
			const patched = patchTree(qc, vaultId, (t) =>
				renameFolders(t, [{ oldPath: old_path, newPath: new_path }]),
			);
			// Deliberately NOT re-pathing descendants' `['note', vaultId, id]`
			// entries: there is no rollback wired for them, so an optimistic flip
			// would show an unconfirmed path if the rename fails. The settle
			// refetch below moves them once the server confirms.
			return { tree, patched };
		},
		onError: (err, _vars, ctx) => {
			restoreTree(qc, vaultId, ctx?.tree, ctx?.patched);
			renameErrorToast(err, "folder");
		},
		onSettled: () => {
			invalidateVaultTree(qc, vaultId);
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
			qc.invalidateQueries({ queryKey: ["note", vaultId] });
		},
	});
}

export function useDeleteNote() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<
		{ deleted: boolean } | undefined,
		ApiError,
		// `path` is unused now that the tree is patched by id, but callers pass it
		// and the CRDT delete signature may want it back; keep it on the contract.
		{ id: string; path: string },
		NoteBodyContext
	>({
		// Delete over the live crdt channel (replaces DELETE /notes/by-id). The ack
		// is idempotent — resolving means durably deleted (even if already gone).
		mutationFn: async ({ id }) => {
			await crdtDeleteNote(id);
			return { deleted: true };
		},
		onMutate: async ({ id }) => {
			const tree = await snapshotTree(qc, vaultId);
			const noteKey = ["note", vaultId, id] as const;
			await qc.cancelQueries({ queryKey: noteKey });
			const prevNote = qc.getQueryData<Note>(noteKey);

			const patched = patchTree(qc, vaultId, (t) => removeNotes(t, [id]));

			// invalidateQueries, not removeQueries: removeQueries destroys the
			// cached Query object outright, which orphans any CURRENTLY MOUNTED
			// useNote(id) observer (e.g. NotePage on the note you just deleted),
			// it keeps rendering the last-known content forever, because nothing
			// forces that specific observer to reconnect to a freshly-built query.
			// invalidateQueries marks the SAME Query object stale and refetches it
			// in place (default refetchType "active"), so every existing observer
			// gets the 404 and NotePage's `error` branch renders correctly instead
			// of a frozen, already-deleted note. See e2e "deleting the open note".
			qc.invalidateQueries({ queryKey: noteKey });
			return { tree, patched, noteId: id, prevNote };
		},
		onError: (err, _vars, ctx) => {
			if (!ctx) {
				return;
			}
			restoreTree(qc, vaultId, ctx.tree, ctx.patched);
			if (ctx.prevNote !== undefined) {
				qc.setQueryData(["note", vaultId, ctx.noteId], ctx.prevNote);
			}
			deleteErrorToast(err, "file");
		},
		onSettled: () => {
			invalidateVaultTree(qc, vaultId);
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
		},
	});
}

export function useDeleteFolder() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<{ deleted: boolean } | undefined, ApiError, { path: string }, TreeContext>({
		// recursive=true: this hook only ever deletes a DERIVED folder (one with no
		// marker row of its own). Without it the server clears a marker that was
		// never there, deletes nothing, and the folder re-derives from the notes
		// still inside it the moment we refetch.
		mutationFn: ({ path }) =>
			api.del<{ deleted: boolean }>(`/folders/${encodePathSegments(path)}?recursive=true`),
		onMutate: async ({ path }) => {
			const tree = await snapshotTree(qc, vaultId);
			// Matches the server's cascade: descendant folders, and the notes and
			// attachments inside them, all go. Attachment-only folders included —
			// they used to survive the optimistic patch and re-derive themselves
			// from a stale attachments cache, undoing the delete on screen.
			const patched = patchTree(qc, vaultId, (t) => removeFolders(t, [path]));
			return { tree, patched };
		},
		onError: (err, _vars, ctx) => {
			restoreTree(qc, vaultId, ctx?.tree, ctx?.patched);
			deleteErrorToast(err, "folder");
		},
		onSettled: () => {
			invalidateVaultTree(qc, vaultId);
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
		},
	});
}

// Duplicate a note: read source content over REST, then genesis-create a
// fresh note at a caller-chosen `new_path` over the CRDT channel. The
// collision-free name is computed by the caller (see
// `viewer/tree-actions/duplicate.ts#nextCopyName`) — keeping this mutation a
// thin GET-then-crdt_create means tests don't need to reason about siblings,
// and the name policy stays in one place.
//
// Optimistic strategy: drop a placeholder NoteSummary into the new
// folder's list immediately so the row appears in the tree. The GET +
// genesis-create happens in the background; on success the placeholder is
// replaced (via onSettled refetch); on error the placeholder is pulled.

export function useDuplicateNote() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<
		{ id: string; path: string },
		ApiError | CrdtOpError,
		{ src_path: string; new_path: string },
		DuplicateNoteContext
	>({
		// Read the source over REST (reads stay REST), then genesis-create the copy
		// WITH content over the crdt channel (crdt_create + b64) — replaces the
		// second leg's POST /notes. The ok reply echoes our minted id.
		mutationFn: async ({ src_path, new_path }) => {
			const src = await api.get<Note>(`/notes/${encodePathSegments(src_path)}`);
			const id = await crdtCreateNoteWithContent(uuid7(), new_path, src.content ?? "");
			return { id, path: new_path };
		},
		onMutate: async ({ new_path }) => {
			const tree = await snapshotTree(qc, vaultId);
			// Placeholder id — the real one arrives with the crdt_create reply.
			// `optimistic-` prefix avoids collisions with real backend uuids;
			// onSuccess swaps it for the server-assigned id.
			const placeholderId = `optimistic-${randomUuid()}`;
			const now = new Date().toISOString();
			const patched = patchTree(qc, vaultId, (t) =>
				upsertNote(t, {
					id: placeholderId,
					path: new_path,
					pending: true,
					created_at: now,
					updated_at: now,
				}),
			);
			return { tree, patched, placeholderId };
		},
		onSuccess: (data, _vars, ctx) => {
			if (!(ctx && data.id)) {
				return;
			}
			// Swap placeholder id → the minted id so a tree consumer keying on
			// `n.id` transitions smoothly (the settle refetch also runs; the swap
			// avoids a momentary "missing note" flash).
			const now = new Date().toISOString();
			patchTree(qc, vaultId, (t) =>
				upsertNote(removeNotes(t, [ctx.placeholderId]), {
					id: data.id,
					path: data.path,
					created_at: now,
					updated_at: now,
				}),
			);
		},
		onError: (err, _vars, ctx) => {
			restoreTree(qc, vaultId, ctx?.tree, ctx?.patched);
			const conflict =
				(err instanceof ApiError && err.status === 409) ||
				(err instanceof CrdtOpError && err.reason === "create_failed");
			if (conflict) {
				toast.error("A note with that name already exists.");
			} else {
				toast.error("Failed to duplicate.");
			}
		},
		onSettled: () => {
			invalidateVaultTree(qc, vaultId);
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
		},
	});
}

// ── Batch mutations (tree multi-select — Task 19) ─────────────
//
// Four hooks fronting `/api/{notes,folders}/batch-{delete,move}`. The
// backend treats every batch atomically (all-or-nothing); the
// `X-Idempotency-Key` header is REQUIRED by the IdempotencyKey plug
// installed in Tasks 7/8 — a missing or replay-on-different-body header
// produces a 4xx the user shouldn't ever see.
//
// Optimistic strategy mirrors the per-row mutations above: snapshot
// `['vault-tree', vaultId]`, patch it, restore it on error, and stale it on
// settle so the server reconciles authoritative state.
//
// `['folderNotes', vaultId, folder]` is invalidated alongside. It is NOT a
// view of the tree — `/folders/list` is its own endpoint feeding the dashboard
// folder-browse screen, which renders tags the tree payload doesn't carry.

export function useBatchDeleteNotes() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<{ deleted: number }, ApiError, { ids: string[] }, TreeContext>({
		// No batch crdt op — one crdt_delete per id, concurrently (replaces
		// POST /notes/batch-delete). ponytail: N round trips + non-atomic — a
		// mid-batch reject fails the whole Promise.all → onError rollback; the
		// onSettled invalidation reconciles server truth on BOTH paths (a partial
		// failure leaves some ids deleted while onError restores every row).
		// Fine for typical multi-selects; add a server batch op if very large
		// selections appear.
		mutationFn: async ({ ids }) => {
			await Promise.all(ids.map((id) => crdtDeleteNote(id)));
			return { deleted: ids.length };
		},
		onMutate: async ({ ids }) => {
			const tree = await snapshotTree(qc, vaultId);
			const patched = patchTree(qc, vaultId, (t) => removeNotes(t, ids));
			// invalidateQueries, not removeQueries: removeQueries destroys the
			// cached Query object outright, which orphans any CURRENTLY MOUNTED
			// useNote(id) observer (e.g. NotePage on the note you just deleted) —
			// it keeps rendering the last-known content forever. See the same note
			// in useDeleteNote, and the e2e "deleting the open note".
			for (const id of ids) {
				qc.invalidateQueries({ queryKey: ["note", vaultId, id] });
			}
			return { tree, patched };
		},
		onError: (_err, _vars, ctx) => {
			restoreTree(qc, vaultId, ctx?.tree, ctx?.patched);
			toast.error("Batch delete failed.");
		},
		onSettled: () => {
			// Reconcile after success AND partial failure — Promise.all is not
			// atomic, so onError's full restore can resurrect already-deleted rows.
			invalidateVaultTree(qc, vaultId);
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
		},
	});
}

export function useBatchMoveNotes() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<
		{ moved: number },
		CrdtOpError,
		{ ids: string[]; target_folder: string; paths?: Record<string, string> },
		TreeContext
	>({
		// Move = one crdt_create per id at `target_folder/<current basename>` (the
		// rename-as-move relocate). `paths` (id → current path) MUST be resolved by
		// the caller BEFORE the optimistic onMutate re-paths the tree — resolving
		// from the cache here would read the already-moved path. No batch op —
		// concurrent, non-atomic; a reject rolls back the whole optimistic move.
		// Replaces POST /notes/batch-move.
		mutationFn: async ({ ids, target_folder, paths = {} }) => {
			await Promise.all(
				ids.map((id) => {
					const cur = paths[id];
					if (cur === undefined) {
						return Promise.resolve();
					}
					return crdtCreateNote(id, joinPath(target_folder, baseOf(cur)));
				}),
			);
			return { moved: ids.length };
		},
		// Folder counts follow automatically: they are recomputed from the notes
		// in the tree, so the source decrement and destination bump that used to
		// be hand-written (and keyed by name, because a derived folder's raw row
		// had a null id) no longer exist.
		onMutate: async ({ ids, target_folder }) => {
			const tree = await snapshotTree(qc, vaultId);
			const patched = patchTree(qc, vaultId, (t) => moveNotes(t, ids, target_folder));
			// Deliberately NOT re-pathing the moved notes' `['note', vaultId, id]`
			// caches: no rollback is wired for them, so an optimistic flip would
			// show an unconfirmed path if the move fails. The settle refetch
			// re-paths them once the server confirms.
			return { tree, patched };
		},
		onError: (_err, _vars, ctx) => {
			restoreTree(qc, vaultId, ctx?.tree, ctx?.patched);
			toast.error("Batch move failed.");
		},
		onSettled: () => {
			// crdt_create per id is non-atomic (Promise.all): a mid-batch reject
			// leaves some ids moved server-side while onError restores every row,
			// so reconcile must run on both paths.
			invalidateVaultTree(qc, vaultId);
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
			qc.invalidateQueries({ queryKey: ["note", vaultId] });
		},
	});
}

export function useBatchDeleteFolders() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<{ deleted: number }, ApiError, { ids: string[] }, TreeContext>({
		mutationFn: ({ ids }) =>
			api.post<{ deleted: number }>("/folders/batch-delete", { ids }, idempotencyHeaders()),
		onMutate: async ({ ids }) => {
			const tree = await snapshotTree(qc, vaultId);
			// No descendant collection: `removeFolders` matches by path prefix, so
			// the server's cascade and ours agree without walking a parent_id
			// chain through rows whose ids are half null.
			const patched = patchTree(qc, vaultId, (t) => removeFolders(t, folderPathsForIds(tree, ids)));
			return { tree, patched };
		},
		onError: (_err, _vars, ctx) => {
			restoreTree(qc, vaultId, ctx?.tree, ctx?.patched);
			toast.error("Batch delete failed.");
		},
		onSettled: () => {
			// Reconcile on both paths: a lost ack (server committed, client saw a
			// network error) or a non-transactional partial delete would otherwise
			// leave onError's restore showing folders the server actually dropped.
			invalidateVaultTree(qc, vaultId);
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
		},
	});
}

export function useBatchMoveFolders() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<
		{ moved: number },
		ApiError,
		{ ids: string[]; target_parent: string },
		TreeContext
	>({
		mutationFn: ({ ids, target_parent }) =>
			api.post<{ moved: number }>(
				"/folders/batch-move",
				// Move by PATH (target_parent) so a derived parent with no marker works.
				{ ids, target_parent },
				idempotencyHeaders(),
			),
		onMutate: async ({ ids, target_parent }) => {
			const tree = await snapshotTree(qc, vaultId);
			const sources = folderPathsForIds(tree, ids);
			// Cycle defense by path: the target is one of the moved folders or
			// sits under one. Skip the optimistic patch and let the server reject
			// (it has the authoritative check). Frontend silence beats lying.
			if (sources.some((src) => isUnder(target_parent, src))) {
				// Nothing patched, so nothing to roll back.
				return { tree, patched: undefined };
			}
			const patched = patchTree(qc, vaultId, (t) => moveFolders(t, sources, target_parent));
			return { tree, patched };
		},
		onError: (_err, _vars, ctx) => {
			restoreTree(qc, vaultId, ctx?.tree, ctx?.patched);
			toast.error("Batch move failed.");
		},
		onSettled: () => {
			// Reconcile on both paths: a lost ack (server committed, client saw a
			// network error) leaves onError's restore showing folders the server
			// actually moved until an unrelated refetch.
			invalidateVaultTree(qc, vaultId);
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
		},
	});
}

export function useRenameAttachment() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<
		{ renamed: boolean; old_path: string; new_path: string },
		ApiError,
		{ old_path: string; new_path: string }
	>({
		mutationFn: (vars) =>
			api.post<{ renamed: boolean; old_path: string; new_path: string }>(
				"/attachments/rename",
				vars,
			),
		onSettled: () => {
			invalidateVaultTree(qc, vaultId);
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
		},
	});
}

export function useBatchMoveAttachments() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<{ moved: number }, ApiError, { paths: string[]; target_folder: string }>({
		mutationFn: ({ paths, target_folder }) =>
			api.post<{ moved: number }>(
				"/attachments/batch-move",
				{ paths, target_folder },
				idempotencyHeaders(),
			),
		onSettled: () => {
			// Reconcile on both paths: a lost ack (server committed, client saw a
			// network error) leaves the attachments shown at their old paths until
			// an unrelated refetch.
			invalidateVaultTree(qc, vaultId);
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
		},
		// Batch moves are fire-and-forget (.mutate, no caller .catch) — surface
		// failures here, matching the note/folder batch hooks.
		onError: () => {
			toast.error("Batch move failed.");
		},
	});
}

export function useBatchDeleteAttachments() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<{ deleted: number }, ApiError, { paths: string[] }>({
		mutationFn: ({ paths }) =>
			api.post<{ deleted: number }>("/attachments/batch-delete", { paths }, idempotencyHeaders()),
		onSettled: () => {
			// Reconcile on both paths: no optimistic removal here, so a lost ack
			// (server committed, client saw a network error) would otherwise leave
			// the deleted attachments visible until an unrelated refetch.
			invalidateVaultTree(qc, vaultId);
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
		},
		onError: () => {
			toast.error("Batch delete failed.");
		},
	});
}
