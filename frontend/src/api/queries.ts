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
import { uuid7 } from "../crdt/uuid7";
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

// Encode each path segment but preserve slashes so Phoenix's splat
// routes match. encodeURIComponent on a full path produces %2F, which
// Plug.Static rejects with 400 InvalidPathError before the router runs.
function encodePathSegments(path: string): string {
	return path.split("/").map(encodeURIComponent).join("/");
}

/**
 * A folder row exactly as `/api/folders` sends it, BEFORE `selectFolders` runs.
 *
 * The distinction from `Folder` is `id`, and it matters: the wire sends `null`
 * for the synthetic root row AND for every *derived* folder (one holding no
 * note directly, which is most of them). `selectFolders` maps those to
 * `syn:<path>` — but `getQueryData` returns the **pre-select** payload, so
 * every raw-cache reader sees the nulls.
 *
 * Typing the raw cache as `{ folders: Folder[] }` (id: string) is what let the
 * #1140 delete-invalidation bug compile: the lookup found a row, so the
 * not-found fallback was skipped, and the invalidation was keyed on
 * `[..., null]` — a key nothing reads, so a note deleted on another device
 * stayed in the sidebar until reload.
 *
 * Use this at every `getQueryData`/`setQueryData` site for the
 * `["folders", vaultId]` key, so the compiler rejects the next reader that
 * forgets. Anything downstream of `select` keeps using `Folder`.
 *
 * NOTE the `Omit`. Writing this as `Folder & { id: string | null }` does
 * NOTHING: TypeScript intersects the property types, and
 * `string & (string | null)` reduces back to `string`. The old inline
 * annotation on `selectFolders`/`folderIdForPath` was exactly that, so it read
 * as if it modelled the null while still letting `.id` be used as a `string`.
 * Omit the field first, then re-add it, or the whole type is decorative.
 */
type RawFolder = Omit<Folder, "id"> & { id: string | null };
interface RawFoldersCache {
	folders: RawFolder[];
}

/**
 * The id a raw row answers to once `selectFolders` has run — a real marker id,
 * else the stable `syn:<path>` id a derived folder carries.
 *
 * Anything that compares raw rows against ids supplied by the tree MUST go
 * through this. The tree only ever holds post-select ids, so a bare
 * `idSet.has(f.id)` silently never matches a derived folder (its raw id is
 * `null`), which is why selecting one for a batch move/delete produced no
 * optimistic patch at all until the server round-trip landed.
 */
const effectiveFolderId = (f: RawFolder): string => f.id ?? syntheticFolderId(f.name);

// Hoisted so React Query treats the select identity as stable; otherwise an
// inline arrow re-runs every render and returns a fresh array, breaking
// memoized consumers (e.g. useEngramTree's rebuild useEffect).
// Drop only the root row; give derived folders a stable synthetic id keyed on
// their path so the `Folder.id: string` contract holds and they aren't erased
// from the tree. synthesizeFolders then links parents/ancestors.
const selectFolders = (data: RawFoldersCache): Folder[] =>
	data.folders
		.filter((f) => f.name !== "")
		.map((f) => (f.id === null ? { ...f, id: syntheticFolderId(f.name) } : (f as Folder)));

const selectNotes = (data: { notes: NoteSummary[] }) => data.notes;

const selectAttachments = (data: { attachments: AttachmentSummary[] }) => data.attachments;

// Single source for the by-id note fetch used by useNote's queryFn.
function fetchNoteById(id: string): Promise<Note> {
	return api.get<Note>(`/notes/by-id/${id}`);
}

interface CreateNoteContext {
	key: readonly unknown[];
	snapshot: NoteSummary[];
	placeholderId: string;
}

// Replace the row whose id === `id` in an id-keyed note-list cache. Used to
// swap an optimistic placeholder for the server row. No-op when the list isn't
// cached.
function patchRowInList(
	qc: QueryClient,
	key: readonly unknown[],
	id: string,
	patch: Partial<NoteSummary>,
): void {
	const cur = qc.getQueryData<NoteSummary[]>(key);
	if (cur) {
		qc.setQueryData<NoteSummary[]>(
			key,
			cur.map((n) => (n.id === id ? { ...n, ...patch } : n)),
		);
	}
}

// Filenames in a note list, ignoring our own optimistic placeholders (so a
// freshly-inserted placeholder doesn't bump the name the server picks).
function realFilenames(notes: NoteSummary[]): Set<string> {
	return new Set(notes.filter((n) => !n.pending).map((n) => n.path.split("/").pop() ?? n.path));
}

// Path → parent folder. `'a/b/c.md'` → `'a/b'`; `'a.md'` → `''`. Same
// rule the backend uses when computing `folder` on a NoteSummary.
function folderOf(path: string): string {
	const slash = path.lastIndexOf("/");
	return slash < 0 ? "" : path.slice(0, slash);
}

// Apply `mut` to the entry at `key` only if it is currently cached.
// Skipping uncached keys keeps optimistic edits cheap and avoids
// pre-seeding caches that would otherwise refetch lazily on mount.
function updateCachedList<T>(
	qc: QueryClient,
	key: readonly unknown[],
	mut: (data: { notes: T[] }) => { notes: T[] },
) {
	const prev = qc.getQueryData<{ notes: T[] }>(key as readonly unknown[]);
	if (!prev) {
		return;
	}
	qc.setQueryData(key as readonly unknown[], mut(prev));
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

interface RenameNoteContext {
	oldFolder: string;
	newFolder: string;
	oldFolderNotes: { notes: NoteSummary[] } | undefined;
	newFolderNotes: { notes: NoteSummary[] } | undefined;
	folders: RawFoldersCache | undefined;
	// The note id is stable across rename — only `path`/`folder` shift.
	// We snapshot the previous note value so rollback restores those
	// fields under the SAME cache key.
	noteId: string | null;
	prevNote: Note | undefined;
	// Snapshot of every id-keyed list we re-pathed. The sidebar tree renders
	// THESE, not the path-keyed `folderNotes` entries above, so they get their
	// own optimistic write — and their own rollback.
	byIdLists: Array<{ key: readonly unknown[]; rows: NoteSummary[] }>;
}

interface RenameFolderContext {
	folders: RawFoldersCache | undefined;
	// Snapshot of every cached folderNotes entry we touched, keyed by the
	// joined query key. Folder rename is coarse (see below) — we DROP all
	// child folderNotes entries to force refetch on next expand, which
	// means rollback needs to restore them.
	childLists: Array<{ key: readonly unknown[]; data: { notes: NoteSummary[] } | undefined }>;
}

interface DeleteNoteContext {
	folder: string;
	id: string;
	folderNotes: { notes: NoteSummary[] } | undefined;
	folders: RawFoldersCache | undefined;
	note: Note | undefined;
}

interface DeleteFolderContext {
	folders: RawFoldersCache | undefined;
	folderList: { notes: NoteSummary[] } | undefined;
}

interface DuplicateNoteContext {
	placeholderId: string;
	// The id-keyed list the tree reads (set only when the target folder's list
	// is cached), plus its snapshot for rollback.
	key?: readonly unknown[];
	snapshot?: NoteSummary[];
}

function idempotencyHeaders(): { headers: Record<string, string> } {
	return { headers: { "X-Idempotency-Key": uuid7() } };
}

interface BatchNotesContext {
	// Every by-id list we patched (root included — it keys under ROOT_FOLDER_ID).
	// We keep the snapshot map ordered by the QueryClient cache scan so rollback
	// restores under the same key.
	noteListSnapshots: Array<{ key: readonly unknown[]; data: NoteSummary[] | undefined }>;
	// Folders cache snapshot — present only when a move patched folder counts
	// (so the tree's structure key changes and it rebuilds). Used for rollback.
	folders?: RawFoldersCache;
}

// Walk the folders cache and collect `id` plus every transitive
// descendant by parent_id chain. Used by both batch folder mutations.
//
// Takes RAW rows and keys on `effectiveFolderId`, so the returned set is in the
// same id space as `rootIds` (which come from the tree, i.e. post-select).
function collectFolderDescendants(folders: RawFolder[], rootIds: string[]): Set<string> {
	const result = new Set<string>(rootIds);
	// Iterate until no new ids land in the set — folders are typically
	// shallow, so this is cheap even with the naive scan.
	let changed = true;
	while (changed) {
		changed = false;
		for (const f of folders) {
			const id = effectiveFolderId(f);
			if (f.parent_id !== null && result.has(f.parent_id) && !result.has(id)) {
				result.add(id);
				changed = true;
			}
		}
	}
	return result;
}

interface BatchFoldersContext {
	folders: RawFoldersCache | undefined;
	// Snapshot every by-id note list whose folder is being deleted so
	// rollback can restore them. Move doesn't touch these lists.
	noteListSnapshots: Array<{ key: readonly unknown[]; data: NoteSummary[] | undefined }>;
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

// Read the one vault-tree query every sidebar view derives from.
//
// `fetchQuery`, NOT `ensureQueryData`: ensureQueryData returns whatever is
// cached the moment `state.data !== undefined` (verified in
// @tanstack/query-core 5.101 — it only consults staleness to fire an OPTIONAL
// background prefetch, and still resolves with the stale value). An invalidated
// tree would therefore keep serving the pre-event snapshot to every derived
// refetch, forever: silent staleness, which is the exact bug this seam was
// rebuilt to remove. `fetchQuery` calls `query.isStaleByTime(...)` first, and
// `isStaleByTime` returns true whenever the query is invalidated — so one
// invalidation produces exactly ONE network fetch, and every derived refetch in
// the same tick dedupes onto that in-flight promise (Query.fetch returns the
// live retryer promise when a fetch is already running).
function fetchVaultTree(qc: QueryClient, vaultId: string | null | undefined): Promise<VaultTree> {
	return qc.fetchQuery(vaultTreeQueryOptions(vaultId));
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

// Resolve a folder PATH (a NoteSummary.folder, or '' for the vault root) to the
// id its note list is cached under. Root maps to the sentinel without a lookup;
// every other folder resolves through the folders cache marker. Returns null
// when an unknown non-root folder isn't in the cache yet — callers skip the
// optimistic patch and let the list surface on its next fetch.
//
// Declared here rather than beside the selectors above so it sits after the
// last non-export statement: `useExportsLast` fires if an export precedes one.
export function folderIdForPath(
	qc: QueryClient,
	vaultId: string | null | undefined,
	folder: string,
): string | null {
	if (folder === "") {
		return ROOT_FOLDER_ID;
	}
	// getQueryData returns the RAW payload — `select: selectFolders` only shapes
	// what components see. So a derived folder still carries `id: null` here, and
	// it must get the same `syn:<path>` id selectFolders would have given it,
	// otherwise this returns null for most real folders and every caller silently
	// skips its optimistic patch.
	const row = qc
		.getQueryData<RawFoldersCache>(["folders", vaultId])
		?.folders.find((f) => f.name === folder);
	if (!row) {
		return null;
	}
	return row.id ?? syntheticFolderId(row.name);
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
	const qc = useQueryClient();
	return useQuery({
		queryKey: ["folders", vaultId],
		// Derived from the one vault-tree read, not a second HTTP request:
		// `folders_payload/2` (lib/engram/notes.ex) is the same backend function
		// behind /api/folders, so these rows are byte-identical to what that
		// endpoint sent — including the synthetic root row (`name === ""`,
		// `id === null`) that `selectFolders` drops so consumers only ever see
		// real folder markers and the `Folder.id: string` contract holds.
		queryFn: async (): Promise<RawFoldersCache> => ({
			folders: (await fetchVaultTree(qc, vaultId)).folders,
		}),
		select: selectFolders,
		// No vault id = nothing to scope the read to. Ungated, a deep link
		// arriving before the bootstrap reconcile lands would fetch (and
		// server-side decrypt) some other vault's whole inventory, then discard it.
		enabled: Boolean(vaultId),
		// Folder listing decrypts every marker row server-side; without a
		// staleTime each remount/window-focus re-derives it (and, once the tree
		// itself is stale, refetches). Mutations and the sync channel
		// (channel.ts) invalidate this key AND the tree, so 60s of staleness only
		// spans gaps nothing else would catch anyway.
		staleTime: FOLDER_NOTES_STALE_MS,
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
	const qc = useQueryClient();
	return useQuery({
		queryKey: ["attachments", vaultId],
		// Derived from the vault tree — `VaultTreeAttachment` IS `AttachmentSummary`
		// (same fields, same units), so the rows pass straight through. `mtime` and
		// `updated_at` must stay the real values: loader.ts sorts attachments by
		// `mtime` under a "modified-*" sort, and use-engram-tree.ts's
		// `attachmentsFingerprint` reads `updated_at` to decide whether to rebuild.
		queryFn: async () => ({ attachments: (await fetchVaultTree(qc, vaultId)).attachments }),
		select: selectAttachments,
		enabled: Boolean(vaultId),
		staleTime: FOLDER_NOTES_STALE_MS,
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
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
			qc.invalidateQueries({ queryKey: ["attachments", vaultId] });
		},
	});
}

// The vault root has no folder-marker row (the by-id endpoint requires a
// non-null id), so it keys its note list under this sentinel — the same value
// the backend already uses as the batch-move root target. One id-space, one
// shape (`NoteSummary[]`), for every folder including root.
export const ROOT_FOLDER_ID = "root";

/**
 * Options for one folder's note list, derived from the vault tree.
 *
 * Shared (not inlined into the hook) because three call sites must build the
 * SAME query — the mounted `useFolderNotesById`, the tree loader's expand path
 * and the sidebar's hover prefetch. When they didn't, the loader's lazily
 * fetched entries ended up with a different (or absent) queryFn from the
 * hook's, which is how an invalidation could reach an entry that had no way to
 * refetch itself.
 */
export function folderNotesByIdQueryOptions(
	qc: QueryClient,
	vaultId: string | null | undefined,
	folderId: string,
) {
	return {
		queryKey: ["folder-notes-by-id", vaultId, folderId] as const,
		queryFn: async (): Promise<NoteSummary[]> => {
			const tree = await fetchVaultTree(qc, vaultId);
			const path = folderPathForId(tree, folderId);
			// `[]` is an ANSWER, not a cache miss: the tree is the vault's whole
			// note inventory, so "this folder holds no notes" is known without
			// asking the server. Falling through to a per-folder request here is
			// what made expanding an empty folder cost a round trip.
			return path === null
				? []
				: tree.notes.filter((n) => folderOf(n.path) === path).map(treeNoteToSummary);
		},
		staleTime: FOLDER_NOTES_STALE_MS,
	};
}

export function useFolderNotesById(folderId: string | null, opts: { enabled?: boolean } = {}) {
	const vaultId = useActiveVaultId();
	const qc = useQueryClient();
	return useQuery({
		...folderNotesByIdQueryOptions(qc, vaultId, folderId as string),
		enabled: folderId !== null && Boolean(vaultId) && (opts.enabled ?? true),
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
 * Stale the vault tree, and with it every view derived from it.
 *
 * Call this wherever `["folders"]` / `["attachments"]` / `["folder-notes-by-id"]`
 * are invalidated, BEFORE them. Those queries re-derive from the tree, so
 * staling one without staling the tree re-derives byte-identical data — and
 * worse, overwrites a just-applied optimistic patch with the pre-mutation
 * snapshot. Over-calling is cheap: every derived refetch in the same tick
 * dedupes onto a single network request.
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
		queryFn: () => fetchNoteById(id as string),
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

	return useMutation<
		{ path: string; id: string },
		ApiError,
		// `name` defaults to "Untitled.md" (the sidebar "New note" button) — the
		// unresolved-wikilink "create this note" affordance passes the target's
		// derived filename instead. Either way collideBump still guards a race.
		{ folder: string; id: string; name?: string },
		CreateNoteContext | undefined
	>({
		mutationFn: async ({ folder, id, name: desiredName = "Untitled.md" }) => {
			const folderId = folderIdForPath(qc, vaultId, folder);
			const existingNotes = folderId
				? (qc.getQueryData<NoteSummary[]>(["folder-notes-by-id", vaultId, folderId]) ?? [])
				: [];
			// Exclude optimistic placeholders so the server name matches the one we
			// showed optimistically (no needless "Untitled 1" bump from our own row).
			const existingNames = realFilenames(existingNotes);

			const MAX_RACES = 5;
			for (let attempt = 0; attempt < MAX_RACES; attempt++) {
				const name = collideBump(existingNames, desiredName, { cap: 1000 });
				const path = folder ? `${folder}/${name}` : name;
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
						existingNames.add(name);
						continue;
					}
					throw err;
				}
			}
			throw new ApiError(500, "useCreateNote: exceeded race retries");
		},
		// Drop a placeholder row into the id-keyed list the tree reads so a new
		// note shows instantly (on-disk feel), then swap it for the server row on
		// success. Root and subfolders share one cache keyed by folder id.
		onMutate: async ({ folder, id, name: desiredName = "Untitled.md" }) => {
			const folderId = folderIdForPath(qc, vaultId, folder);
			// Unknown non-root folder not in the cache yet — skip; surfaces on expand.
			if (folderId === null) {
				return;
			}
			const key = ["folder-notes-by-id", vaultId, folderId] as const;
			await qc.cancelQueries({ queryKey: key });

			const snapshot = qc.getQueryData<NoteSummary[]>(key);
			// Not cached (e.g. an unexpanded subfolder) — skip; it surfaces on expand.
			if (snapshot === undefined) {
				return;
			}

			const name = collideBump(realFilenames(snapshot), desiredName, { cap: 1000 });
			const path = folder ? `${folder}/${name}` : name;
			const now = new Date().toISOString();
			const placeholder: NoteSummary = {
				// The id we're about to send, not a throwaway: the row is addressable
				// the moment it appears, so clicking it before the ack opens the right
				// note instead of a dead `optimistic-…` route.
				id,
				pending: true,
				path,
				title: name.replace(/\.md$/u, ""),
				folder,
				tags: [],
				version: 1,
				mtime: now,
				created_at: now,
				updated_at: now,
			};

			qc.setQueryData<NoteSummary[]>(key, [...snapshot, placeholder]);
			return { key, snapshot, placeholderId: id };
		},
		onSuccess: ({ id, path }, vars, ctx) => {
			// FIRST, before any derived key below is invalidated: those re-derive
			// from the tree, and a tree fetched before this create would revert the
			// optimistic row we just settled.
			invalidateVaultTree(qc, vaultId);
			// Swap the placeholder for the server-assigned id/path.
			if (ctx) {
				const filename = path.split("/").pop() ?? path;
				// Id already matches — only the confirmed path/title and the pending
				// flag need settling.
				patchRowInList(qc, ctx.key, ctx.placeholderId, {
					path,
					title: filename.replace(/\.md$/u, ""),
					pending: false,
				});
				// Only the target folder's list changed — no need to stale the whole
				// prefix (which would force every folder to refetch on next expand).
				qc.invalidateQueries({ queryKey: ctx.key });
			} else {
				// No ctx = the folder's list wasn't cached (collapsed, never opened),
				// so there was no placeholder to swap. Still mark it stale, or the
				// note stays invisible there until a reload.
				const folderId = folderIdForPath(qc, vaultId, vars.folder);
				if (folderId !== null) {
					qc.invalidateQueries({ queryKey: ["folder-notes-by-id", vaultId, folderId] });
				}
			}
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
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
			navigate(slug ? `/${slug}/${id}` : `/note/${id}`, { state: { justCreated: true } });
		},
		onError: (err, _vars, ctx) => {
			if (ctx) {
				qc.setQueryData(ctx.key, ctx.snapshot);
			}
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
			const cached = qc.getQueryData<RawFoldersCache>(["folders", vaultId]);
			const existingFolders = cached?.folders.map((f) => f.name) ?? [];

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
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
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
		queryFn: () => api.get<{ tags: string[] }>("/tags"),
		select: (data) => data.tags,
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
			await api.del<void>(`/me?password=${encodeURIComponent(password)}`);
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

export interface BootstrapPayload {
	onboarding: OnboardingStatus;
	capabilities: Capabilities;
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
	key_id: string | null;
	name: string | null;
	software_id: string | null;
	software_version: string | null;
	verified: boolean;
	logo: string | null;
	slug: string | null;
	vault_id: string | null;
	vault_name: string | null;
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

export function useRevokeOauthConnection() {
	const qc = useQueryClient();
	return useMutation({
		mutationFn: (clientId: string) => api.del(`/connections/oauth/${clientId}`),
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

// Vault types (encryption fields are the ones we care about for settings)

export type EncryptionStatus = "none" | "encrypting" | "encrypted" | "decrypt_pending";

export interface Vault {
	id: string;
	name: string;
	description: string | null;
	slug: string;
	is_default: boolean;
	created_at: string;
	encrypted: boolean;
	encryption_status: EncryptionStatus;
	encrypted_at: string | null;
	decrypt_requested_at: string | null;
	last_toggle_at: string | null;
	cooldown_days: number | null;
	deleted_at?: string | null;
	purge_at?: string | null;
	note_count?: number;
	attachment_count?: number;
}

export interface EncryptionProgress {
	processed: number;
	total: number;
	status: EncryptionStatus;
	started_at: string | null;
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

export function useEncryptionProgress(vaultId: string | undefined, enabled: boolean) {
	return useQuery({
		queryKey: ["encryption-progress", vaultId],
		queryFn: () => api.get<EncryptionProgress>(`/vaults/${vaultId}/encryption_progress`),
		enabled: enabled && vaultId !== undefined,
		refetchInterval: enabled ? 3000 : false,
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
		mutationFn: (attrs: { name: string; description?: string }) =>
			api.post<{ vault: Vault }>("/vaults", attrs),
		onSuccess: () => {
			qc.invalidateQueries({ queryKey: ["vaults"] });
			// Backend records `first_vault_created` in Vaults.create_vault/2;
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
		RenameNoteContext
	>({
		// Rename/move = crdt_create for a KNOWN live id at a new FREE path — the
		// backend relocates the row in place (rename-as-move, notes.ex Phase E2),
		// keeping the note_id + content. A path OCCUPIED by a different note comes
		// back as create_failed. Replaces POST /notes/rename.
		mutationFn: async ({ id, old_path, new_path }) => {
			await crdtCreateNote(id, new_path);
			return { renamed: true, old_path, new_path };
		},
		onMutate: async ({ old_path, new_path }) => {
			const oldFolder = folderOf(old_path);
			const newFolder = folderOf(new_path);
			const oldListKey = ["folderNotes", vaultId, oldFolder] as const;
			const newListKey = ["folderNotes", vaultId, newFolder] as const;
			const foldersKey = ["folders", vaultId] as const;

			// Stop in-flight queries from clobbering the optimistic write.
			await qc.cancelQueries({ queryKey: ["folderNotes", vaultId] });
			await qc.cancelQueries({ queryKey: foldersKey });
			await qc.cancelQueries({ queryKey: ["note", vaultId] });

			const oldFolderNotes = qc.getQueryData<{ notes: NoteSummary[] }>(oldListKey);
			const newFolderNotes = qc.getQueryData<{ notes: NoteSummary[] }>(newListKey);
			const folders = qc.getQueryData<RawFoldersCache>(foldersKey);

			// Resolve the note id from whatever cache has it. The folder
			// list is the cheapest lookup; failing that, walk every cached
			// `['note', vaultId, *]` entry looking for the matching path.
			const fromList = oldFolderNotes?.notes.find((n) => n.path === old_path);
			let noteId: string | null = fromList?.id ?? null;
			let prevNote: Note | undefined;
			if (noteId === null) {
				const cached = qc
					.getQueryCache()
					.findAll({ queryKey: ["note", vaultId] })
					.map((q) => q.state.data as Note | undefined)
					.find((n) => n?.path === old_path);
				if (cached) {
					noteId = cached.id;
					prevNote = cached;
				}
			} else {
				prevNote = qc.getQueryData<Note>(["note", vaultId, noteId]);
			}

			// Re-path the note wherever the tree caches it. Matching by id when we
			// resolved one, else by old path. A rename keeps the note in its
			// folder (both inline-rename entry points edit the leaf only), so an
			// in-place re-path is enough; onSettled's refetch reconciles folder
			// membership in the theoretical slash-typed move case.
			const matchesRow = (n: NoteSummary) =>
				noteId === null ? n.path === old_path : n.id === noteId;
			const byIdLists: RenameNoteContext["byIdLists"] = [];
			for (const q of qc.getQueryCache().findAll({ queryKey: ["folder-notes-by-id", vaultId] })) {
				const rows = q.state.data as NoteSummary[] | undefined;
				if (!rows?.some(matchesRow)) {
					continue;
				}
				byIdLists.push({ key: q.queryKey, rows });
				qc.setQueryData<NoteSummary[]>(
					q.queryKey,
					rows.map((n) => (matchesRow(n) ? { ...n, path: new_path, folder: newFolder } : n)),
				);
			}

			const ctx: RenameNoteContext = {
				oldFolder,
				newFolder,
				oldFolderNotes,
				newFolderNotes,
				folders,
				noteId,
				prevNote,
				byIdLists,
			};

			// Build a renamed NoteSummary either from the existing list row
			// or from the cached note body so the new folder list still gets
			// a visible entry even when the old list isn't cached.
			const renamedSummary: NoteSummary | null = fromList
				? { ...fromList, path: new_path, folder: newFolder }
				: prevNote
					? {
							id: prevNote.id,
							path: new_path,
							title: prevNote.title,
							folder: newFolder,
							tags: prevNote.tags,
							version: prevNote.version,
							mtime: prevNote.mtime,
							created_at: prevNote.created_at,
							updated_at: prevNote.updated_at,
						}
					: null;

			// Remove from old list (by id when we have it, by path otherwise).
			if (oldFolderNotes) {
				updateCachedList<NoteSummary>(qc, oldListKey, (prev) => ({
					notes: prev.notes.filter((n) =>
						noteId === null ? n.path !== old_path : n.id !== noteId,
					),
				}));
			}

			// Drop a renamed copy into the new folder list (if cached).
			if (renamedSummary && newFolderNotes) {
				updateCachedList<NoteSummary>(qc, newListKey, (prev) => ({
					notes: [
						...prev.notes.filter((n) => (noteId === null ? n.path !== new_path : n.id !== noteId)),
						renamedSummary,
					],
				}));
			}

			// Adjust folder counts when the note crosses folder boundaries.
			if (oldFolder !== newFolder && folders) {
				qc.setQueryData<RawFoldersCache>(foldersKey, (prev) => {
					if (!prev) {
						return prev;
					}
					let next = prev.folders.map((f) =>
						f.name === oldFolder ? { ...f, count: Math.max(0, f.count - 1) } : f,
					);
					const hasNewEntry = next.some((f) => f.name === newFolder);
					if (hasNewEntry) {
						next = next.map((f) => (f.name === newFolder ? { ...f, count: f.count + 1 } : f));
					} else if (newFolder === "") {
						// Root files don't get a synthetic '' entry — folders() filters
						// those out anyway; the note shows up via RootFiles.
					} else {
						// Optimistic placeholder — real backend id + parent_id land
						// when `onSettled` refetches the folders list. The `optimistic-`
						// sentinel id won't collide with real uuids; the null parent_id
						// is benign because the refetch reconciles before any consumer
						// can rely on tree shape here.
						next = [
							...next,
							{
								id: `optimistic-${uuid7()}`,
								parent_id: null,
								name: newFolder,
								count: 1,
							},
						];
					}
					return { folders: next };
				});
			}

			// Re-path the note-body cache too, so an open editor's header flips
			// the moment the user commits instead of lagging until onSettled's
			// refetch. This was once deliberately skipped: the editor keyed its
			// CRDT doc on `note.path`, so an early re-path made it enroll the new
			// path before the rename committed, which the channel bootstrapped
			// into a duplicate note that then 409'd the rename. note-page.tsx now
			// keys the doc on `note.id` (stable across a rename) and reads `path`
			// only for display + the `.md` gate, so that hazard is gone — and
			// `ctx.prevNote` gives onError an exact rollback if the create is
			// refused.
			if (noteId !== null && prevNote) {
				qc.setQueryData<Note>(["note", vaultId, noteId], {
					...prevNote,
					path: new_path,
					folder: newFolder,
				});
			}

			return ctx;
		},
		onError: (err, _vars, ctx) => {
			if (!ctx) {
				return;
			}
			const oldListKey = ["folderNotes", vaultId, ctx.oldFolder];
			const newListKey = ["folderNotes", vaultId, ctx.newFolder];
			const foldersKey = ["folders", vaultId];
			if (ctx.oldFolderNotes !== undefined) {
				qc.setQueryData(oldListKey, ctx.oldFolderNotes);
			}
			if (ctx.newFolderNotes !== undefined) {
				qc.setQueryData(newListKey, ctx.newFolderNotes);
			}
			if (ctx.folders !== undefined) {
				qc.setQueryData(foldersKey, ctx.folders);
			}
			for (const { key, rows } of ctx.byIdLists) {
				qc.setQueryData<NoteSummary[]>(key, rows);
			}
			// Undo the optimistic re-path so a refused rename can't leave the
			// header showing a name the server never accepted.
			if (ctx.noteId !== null && ctx.prevNote) {
				qc.setQueryData<Note>(["note", vaultId, ctx.noteId], ctx.prevNote);
			}
			renameErrorToast(err, "file");
		},
		onSettled: () => {
			invalidateVaultTree(qc, vaultId);
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
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
		RenameFolderContext
	>({
		mutationFn: (vars) =>
			api.post<{
				renamed: boolean;
				old_path: string;
				new_path: string;
				count: number;
			}>("/folders/rename", vars),
		onMutate: async ({ old_path, new_path }) => {
			// COARSE optimistic strategy: rewrite folder names in ['folders']
			// (the renamed folder + every descendant) and DROP every cached
			// folderNotes entry under the old prefix. Note paths inside those
			// lists would need full prefix-rewrite to stay coherent, and the
			// user almost certainly isn't looking at every descendant list at
			// once — refetching on next expand is cheap and exact. The list
			// for the renamed folder ITSELF gets the same treatment.
			const foldersKey = ["folders", vaultId] as const;
			await qc.cancelQueries({ queryKey: ["folderNotes", vaultId] });
			await qc.cancelQueries({ queryKey: foldersKey });

			await qc.cancelQueries({ queryKey: ["note", vaultId] });

			const ctx: RenameFolderContext = {
				folders: qc.getQueryData<RawFoldersCache>(foldersKey),
				childLists: [],
			};

			// Rewrite folder names.
			if (ctx.folders) {
				qc.setQueryData<RawFoldersCache>(foldersKey, (prev) => {
					if (!prev) {
						return prev;
					}
					const oldPrefix = `${old_path}/`;
					return {
						folders: prev.folders.map((f) => {
							if (f.name === old_path) {
								return { ...f, name: new_path };
							}
							if (f.name.startsWith(oldPrefix)) {
								return { ...f, name: `${new_path}/${f.name.slice(oldPrefix.length)}` };
							}
							return f;
						}),
					};
				});
			}

			// Snapshot + drop every cached folderNotes entry under the old prefix.
			const all = qc.getQueryCache().findAll({ queryKey: ["folderNotes", vaultId] });
			for (const q of all) {
				const folder = q.queryKey[2] as string | undefined;
				if (typeof folder !== "string") {
					continue;
				}
				if (folder !== old_path && !folder.startsWith(`${old_path}/`)) {
					continue;
				}
				ctx.childLists.push({
					key: q.queryKey,
					data: qc.getQueryData<{ notes: NoteSummary[] }>(q.queryKey),
				});
				qc.removeQueries({ queryKey: q.queryKey });
			}

			// Deliberately do NOT re-path cached `['note', vaultId, id]` entries for
			// descendants here. An open child note's editor keys its CRDT doc on
			// `note.id`, which is stable across a folder rename, so there's no
			// doc-reopen or bootstrap-by-path race to avoid anymore. Still skipped
			// because there's no rollback wired for these entries — an optimistic
			// `path` flip would show an unconfirmed path if the rename fails.
			// onSettled's `['note', vaultId]` refetch moves the note caches after
			// the server confirms, matching the (passing) folder-move path.
			return ctx;
		},
		onError: (err, _vars, ctx) => {
			if (!ctx) {
				return;
			}
			if (ctx.folders !== undefined) {
				qc.setQueryData(["folders", vaultId], ctx.folders);
			}
			for (const entry of ctx.childLists) {
				if (entry.data !== undefined) {
					qc.setQueryData(entry.key, entry.data);
				}
			}
			// No note-cache rollback: onMutate no longer re-paths `['note', id]`.
			renameErrorToast(err, "folder");
		},
		onSettled: () => {
			invalidateVaultTree(qc, vaultId);
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
			qc.invalidateQueries({ queryKey: ["note", vaultId] });
		},
	});
}

// `path` rides along so optimistic onMutate can locate the row in the
// folderNotes cache + adjust the parent folder's count without a round
// trip. The URL itself only needs the id.
export function useDeleteNote() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<
		{ deleted: boolean } | undefined,
		ApiError,
		{ id: string; path: string },
		DeleteNoteContext
	>({
		// Delete over the live crdt channel (replaces DELETE /notes/by-id). The ack
		// is idempotent — resolving means durably deleted (even if already gone).
		mutationFn: async ({ id }) => {
			await crdtDeleteNote(id);
			return { deleted: true };
		},
		onMutate: async ({ id, path }) => {
			const folder = folderOf(path);
			const listKey = ["folderNotes", vaultId, folder] as const;
			const foldersKey = ["folders", vaultId] as const;
			const noteKey = ["note", vaultId, id] as const;

			await qc.cancelQueries({ queryKey: ["folderNotes", vaultId] });
			await qc.cancelQueries({ queryKey: foldersKey });
			await qc.cancelQueries({ queryKey: noteKey });

			const ctx: DeleteNoteContext = {
				folder,
				id,
				folderNotes: qc.getQueryData<{ notes: NoteSummary[] }>(listKey),
				folders: qc.getQueryData<RawFoldersCache>(foldersKey),
				note: qc.getQueryData<Note>(noteKey),
			};

			if (ctx.folderNotes) {
				updateCachedList<NoteSummary>(qc, listKey, (prev) => ({
					notes: prev.notes.filter((n) => n.id !== id),
				}));
			}
			if (ctx.folders) {
				qc.setQueryData<RawFoldersCache>(foldersKey, (prev) =>
					prev
						? {
								folders: prev.folders.map((f) =>
									f.name === folder ? { ...f, count: Math.max(0, f.count - 1) } : f,
								),
							}
						: prev,
				);
			}
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
			return ctx;
		},
		onError: (err, _vars, ctx) => {
			if (!ctx) {
				return;
			}
			const listKey = ["folderNotes", vaultId, ctx.folder];
			const foldersKey = ["folders", vaultId];
			const noteKey = ["note", vaultId, ctx.id];
			if (ctx.folderNotes !== undefined) {
				qc.setQueryData(listKey, ctx.folderNotes);
			}
			if (ctx.folders !== undefined) {
				qc.setQueryData(foldersKey, ctx.folders);
			}
			if (ctx.note !== undefined) {
				qc.setQueryData(noteKey, ctx.note);
			}
			deleteErrorToast(err, "file");
		},
		onSettled: () => {
			invalidateVaultTree(qc, vaultId);
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
		},
	});
}

export function useDeleteFolder() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<
		{ deleted: boolean } | undefined,
		ApiError,
		{ path: string },
		DeleteFolderContext
	>({
		mutationFn: ({ path }) => api.del<{ deleted: boolean }>(`/folders/${encodePathSegments(path)}`),
		onMutate: async ({ path }) => {
			// Coarse: drop the folder entry + its own folderNotes cache. We
			// don't chase descendant folderNotes entries — the user will
			// refetch them next time they expand the (now nonexistent) child.
			const foldersKey = ["folders", vaultId] as const;
			const listKey = ["folderNotes", vaultId, path] as const;

			await qc.cancelQueries({ queryKey: foldersKey });
			await qc.cancelQueries({ queryKey: listKey });

			const ctx: DeleteFolderContext = {
				folders: qc.getQueryData<RawFoldersCache>(foldersKey),
				folderList: qc.getQueryData<{ notes: NoteSummary[] }>(listKey),
			};

			if (ctx.folders) {
				qc.setQueryData<RawFoldersCache>(foldersKey, (prev) =>
					prev
						? {
								folders: prev.folders.filter(
									(f) => f.name !== path && !f.name.startsWith(`${path}/`),
								),
							}
						: prev,
				);
			}
			qc.removeQueries({ queryKey: listKey });
			return ctx;
		},
		onError: (err, vars, ctx) => {
			if (!ctx) {
				return;
			}
			if (ctx.folders !== undefined) {
				qc.setQueryData(["folders", vaultId], ctx.folders);
			}
			if (ctx.folderList !== undefined) {
				qc.setQueryData(["folderNotes", vaultId, vars.path], ctx.folderList);
			}
			deleteErrorToast(err, "folder");
		},
		onSettled: () => {
			invalidateVaultTree(qc, vaultId);
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
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
		// WITH content over the crdt channel (crdt_create_batch) — replaces the
		// second leg's POST /notes. The ok reply echoes our minted id.
		mutationFn: async ({ src_path, new_path }) => {
			const src = await api.get<Note>(`/notes/${encodePathSegments(src_path)}`);
			const id = await crdtCreateNoteWithContent(uuid7(), new_path, src.content ?? "");
			return { id, path: new_path };
		},
		onMutate: async ({ src_path, new_path }) => {
			const newFolder = folderOf(new_path);
			const targetId = folderIdForPath(qc, vaultId, newFolder);

			// Placeholder id — the real one arrives with the crdt_create reply.
			// `optimistic-` prefix avoids collisions with real backend uuids;
			// onSuccess swaps it for the server-assigned id in the cached list.
			const placeholderId = `optimistic-${uuid7()}`;
			const ctx: DuplicateNoteContext = { placeholderId };

			// Seed metadata from the source row if we have it cached — gives
			// the placeholder a usable title/tags so the row looks real.
			const srcId = folderIdForPath(qc, vaultId, folderOf(src_path));
			const srcRow = srcId
				? qc
						.getQueryData<NoteSummary[]>(["folder-notes-by-id", vaultId, srcId])
						?.find((n) => n.path === src_path)
				: undefined;
			const now = new Date().toISOString();
			const placeholder: NoteSummary = {
				id: placeholderId,
				// Marks the row as not-yet-acked for realFilenames, which used to infer
				// that from the `optimistic-` id prefix.
				pending: true,
				path: new_path,
				title: srcRow?.title ?? "",
				folder: newFolder,
				tags: srcRow?.tags ?? [],
				version: 1,
				mtime: now,
				created_at: now,
				updated_at: now,
			};

			// Drop the placeholder into the id-keyed list the tree reads (root or
			// subfolder). Only patch when cached; otherwise it lands on the next
			// expand fetch. Cancel first so an in-flight refetch can't clobber it.
			if (targetId !== null) {
				const key = ["folder-notes-by-id", vaultId, targetId] as const;
				await qc.cancelQueries({ queryKey: key });
				const snapshot = qc.getQueryData<NoteSummary[]>(key);
				if (snapshot) {
					ctx.key = key;
					ctx.snapshot = snapshot;
					qc.setQueryData<NoteSummary[]>(key, [
						...snapshot.filter((n) => n.path !== new_path),
						placeholder,
					]);
				}
			}
			return ctx;
		},
		onSuccess: (data, _vars, ctx) => {
			if (!(ctx?.key && data.id)) {
				return;
			}
			// The placeholder already carries the copied fields (title/tags/folder);
			// only the id is provisional. Swap placeholder id → the minted id so a
			// tree consumer keying on `n.id` transitions smoothly (onSettled also
			// invalidates; the swap avoids a momentary "missing note" flash).
			patchRowInList(qc, ctx.key, ctx.placeholderId, { id: data.id, path: data.path });
		},
		onError: (err, _vars, ctx) => {
			if (ctx?.key && ctx.snapshot !== undefined) {
				qc.setQueryData(ctx.key, ctx.snapshot);
			}
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
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
			qc.invalidateQueries({ queryKey: ["folder-notes-by-id", vaultId] });
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
// affected caches on `onMutate`, patch them locally, restore on error,
// invalidate on success so the server reconciles authoritative state
// (folder counts, server-assigned timestamps, etc.).
//
// Cache keys we touch:
//   `['folders', vaultId]`              — the folder tree (id, parent_id, name)
//   `['folder-notes-by-id', vaultId, folderId]` — by-id note lists
//
// `['folderNotes', vaultId, folder]` (path-keyed) is invalidated alongside
// for the legacy tree consumers that still read it; the batch onMutate
// itself only patches the id-keyed list since headless-tree is the only
// caller that issues batches.

export function useBatchDeleteNotes() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<{ deleted: number }, ApiError, { ids: string[] }, BatchNotesContext>({
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
			await qc.cancelQueries({ queryKey: ["folder-notes-by-id", vaultId] });
			const idSet = new Set(ids);

			// One id-keyed cache holds every note list (root keys under
			// ROOT_FOLDER_ID), so a single scan strips deleted rows everywhere.
			const snapshots: BatchNotesContext["noteListSnapshots"] = [];
			const queries = qc.getQueryCache().findAll({ queryKey: ["folder-notes-by-id", vaultId] });
			for (const q of queries) {
				const data = qc.getQueryData<NoteSummary[]>(q.queryKey);
				if (!data) {
					continue;
				}
				snapshots.push({ key: q.queryKey, data });
				qc.setQueryData<NoteSummary[]>(
					q.queryKey,
					data.filter((n) => !idSet.has(n.id)),
				);
			}

			// invalidateQueries, not removeQueries: removeQueries destroys the
			// cached Query object outright, which orphans any CURRENTLY MOUNTED
			// useNote(id) observer (e.g. NotePage on the note you just deleted),
			// it keeps rendering the last-known content forever, because nothing
			// forces that specific observer to reconnect to a freshly-built query.
			// invalidateQueries marks the SAME Query object stale and refetches it
			// in place (default refetchType "active"), so every existing observer
			// (including a stale remount later) gets the 404 and NotePage's
			// `error` branch renders correctly. See e2e "deleting the open note".
			for (const id of ids) {
				qc.invalidateQueries({ queryKey: ["note", vaultId, id] });
			}

			return { noteListSnapshots: snapshots };
		},
		onError: (_err, _vars, ctx) => {
			if (!ctx) {
				return;
			}
			for (const snap of ctx.noteListSnapshots) {
				qc.setQueryData(snap.key, snap.data);
			}
			toast.error("Batch delete failed.");
		},
		onSettled: () => {
			// Reconcile after success AND partial failure — Promise.all is not
			// atomic, so onError's full restore can resurrect already-deleted rows.
			invalidateVaultTree(qc, vaultId);
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folder-notes-by-id", vaultId] });
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
		BatchNotesContext
	>({
		// Move = one crdt_create per id at `target_folder/<current basename>` (the
		// rename-as-move relocate). `paths` (id → current path) MUST be resolved by
		// the caller BEFORE the optimistic onMutate re-paths the cache — resolving
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
					const leaf = cur.split("/").pop() ?? cur;
					const newPath = target_folder ? `${target_folder}/${leaf}` : leaf;
					return crdtCreateNote(id, newPath);
				}),
			);
			return { moved: ids.length };
		},
		onMutate: async ({ ids, target_folder }) => {
			await qc.cancelQueries({ queryKey: ["folder-notes-by-id", vaultId] });
			await qc.cancelQueries({ queryKey: ["folders", vaultId] });
			const idSet = new Set(ids);

			// Destination is the folder PATH ('' = vault root). The by-id note cache
			// keys under the folder's loader id — a real marker id, else the stable
			// `syn:<path>` id a derived folder carries — so the optimistic add lands
			// in the same list the tree reads.
			const foldersCache = qc.getQueryData<RawFoldersCache>(["folders", vaultId]);
			const targetFolderName = target_folder;
			const targetCacheId =
				target_folder === ""
					? ROOT_FOLDER_ID
					: (foldersCache?.folders.find((f) => f.name === target_folder)?.id ??
						syntheticFolderId(target_folder));

			const snapshots: BatchNotesContext["noteListSnapshots"] = [];
			const moved: NoteSummary[] = [];
			// How many notes left each source folder, keyed by folder NAME — used to
			// decrement folder counts below. Keyed by name (not id) because a derived
			// folder's raw `['folders']` row has a null id, so id matching would miss
			// it; the note lists, however, are keyed by the loader id (real or syn:).
			const removedPerName = new Map<string, number>();

			// First pass: strip moved notes from every source list (capture the rows
			// so we can re-attach them to the target). Root and subfolders share one
			// id-keyed cache, so a single scan covers them all.
			for (const q of qc.getQueryCache().findAll({ queryKey: ["folder-notes-by-id", vaultId] })) {
				const data = qc.getQueryData<NoteSummary[]>(q.queryKey);
				if (!data) {
					continue;
				}
				snapshots.push({ key: q.queryKey, data });
				const folderId = q.queryKey[2] as string | null | undefined;
				// Resolve this source list's folder PATH so the count decrement matches
				// the raw folders cache by name (root sentinel → '', syn:<path> → path,
				// real id → its cached name).
				const srcName =
					typeof folderId === "string"
						? folderId === ROOT_FOLDER_ID
							? ""
							: isSyntheticFolderId(folderId)
								? syntheticFolderPath(folderId)
								: (foldersCache?.folders.find((ff) => ff.id === folderId)?.name ?? null)
						: null;
				const keep: NoteSummary[] = [];
				for (const n of data) {
					if (idSet.has(n.id) && folderId !== targetCacheId) {
						moved.push(n);
						if (srcName !== null) {
							removedPerName.set(srcName, (removedPerName.get(srcName) ?? 0) + 1);
						}
					} else {
						keep.push(n);
					}
				}
				qc.setQueryData<NoteSummary[]>(q.queryKey, keep);
			}

			// Second pass: append the moved rows to the destination list (if cached),
			// rewriting folder + path so each row looks at-home. The target keys
			// under its id — ROOT_FOLDER_ID for the vault root.
			if (moved.length > 0) {
				const dest = targetFolderName;
				const patched = moved.map<NoteSummary>((n) => {
					const filename = n.path.includes("/")
						? n.path.slice(n.path.lastIndexOf("/") + 1)
						: n.path;
					return { ...n, folder: dest, path: dest ? `${dest}/${filename}` : filename };
				});
				const targetKey = ["folder-notes-by-id", vaultId, targetCacheId] as const;
				const targetData = qc.getQueryData<NoteSummary[]>(targetKey);
				if (targetData) {
					qc.setQueryData<NoteSummary[]>(targetKey, [...targetData, ...patched]);
				}
			}

			// Deliberately do NOT re-path the moved notes' `['note', vaultId, id]`
			// caches here. An open editor keys its CRDT doc on `note.id`, which is
			// stable across a move, so there's no doc-reopen or bootstrap-by-path
			// race to avoid anymore. Still skipped because there's no rollback
			// wired for these entries — an optimistic `path` flip would show an
			// unconfirmed path if the move fails. onSuccess's `['note', vaultId]`
			// refetch re-paths the note cache after the server confirms (the
			// folder-list + count patches below keep the tree snappy).

			// Bump folder counts: each source loses what it shed, the target gains
			// the total moved. Two reasons, both load-bearing: (1) keeps the folder
			// count value accurate (used by the delete-confirm child count) without a
			// refetch, and (2) flips the folders cache so the tree's structure key
			// (id:count:parent_id) changes and it rebuilds. The by-id cache write
			// also rebuilds via the useEngramTree subscription, so this is belt-and-
			// suspenders for rebuild but the SOLE optimistic source for the count.
			// Snapshot for rollback. Skipped when nothing moved; for a root target
			// ('root' has no folder row) sources still decrement.
			let foldersSnapshot: RawFoldersCache | undefined;
			if (moved.length > 0 || removedPerName.size > 0) {
				const cache = qc.getQueryData<RawFoldersCache>(["folders", vaultId]);
				if (cache) {
					foldersSnapshot = cache;
					const patched = cache.folders.map((f) => {
						let { count } = f;
						// Both source decrement and destination bump match by NAME: a
						// derived folder has a null id in the raw cache, so id matching
						// would miss it.
						const removed = removedPerName.get(f.name);
						if (removed) {
							count -= removed;
						}
						if (target_folder !== "" && f.name === target_folder) {
							count += moved.length;
						}
						return count === f.count ? f : { ...f, count };
					});
					qc.setQueryData<RawFoldersCache>(["folders", vaultId], { folders: patched });
				}
			}

			return { noteListSnapshots: snapshots, folders: foldersSnapshot };
		},
		onError: (_err, _vars, ctx) => {
			if (!ctx) {
				return;
			}
			for (const snap of ctx.noteListSnapshots) {
				qc.setQueryData(snap.key, snap.data);
			}
			if (ctx.folders !== undefined) {
				qc.setQueryData(["folders", vaultId], ctx.folders);
			}
			toast.error("Batch move failed.");
		},
		onSettled: () => {
			// crdt_create per id is non-atomic (Promise.all): a mid-batch reject
			// leaves some ids moved server-side while onError restores every row,
			// so reconcile must run on both paths.
			invalidateVaultTree(qc, vaultId);
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folder-notes-by-id", vaultId] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
			qc.invalidateQueries({ queryKey: ["note", vaultId] });
		},
	});
}

export function useBatchDeleteFolders() {
	const qc = useQueryClient();
	const vaultId = useActiveVaultId();
	return useMutation<{ deleted: number }, ApiError, { ids: string[] }, BatchFoldersContext>({
		mutationFn: ({ ids }) =>
			api.post<{ deleted: number }>("/folders/batch-delete", { ids }, idempotencyHeaders()),
		onMutate: async ({ ids }) => {
			const foldersKey = ["folders", vaultId] as const;
			await qc.cancelQueries({ queryKey: foldersKey });
			await qc.cancelQueries({ queryKey: ["folder-notes-by-id", vaultId] });

			const folders = qc.getQueryData<RawFoldersCache>(foldersKey);
			const ctx: BatchFoldersContext = { folders, noteListSnapshots: [] };

			// Compute the full set of ids (roots + transitive descendants)
			// so the optimistic patch matches the server's cascade.
			const removedIds = folders
				? collectFolderDescendants(folders.folders, ids)
				: new Set<string>(ids);

			if (folders) {
				qc.setQueryData<RawFoldersCache>(foldersKey, {
					folders: folders.folders.filter((f) => !removedIds.has(effectiveFolderId(f))),
				});
			}

			// Drop the by-id note lists for every removed folder.
			for (const fid of removedIds) {
				const key = ["folder-notes-by-id", vaultId, fid] as const;
				const data = qc.getQueryData<NoteSummary[]>(key);
				if (data !== undefined) {
					ctx.noteListSnapshots.push({ key, data });
					qc.removeQueries({ queryKey: key });
				}
			}

			return ctx;
		},
		onError: (_err, _vars, ctx) => {
			if (!ctx) {
				return;
			}
			if (ctx.folders !== undefined) {
				qc.setQueryData(["folders", vaultId], ctx.folders);
			}
			for (const snap of ctx.noteListSnapshots) {
				qc.setQueryData(snap.key, snap.data);
			}
			toast.error("Batch delete failed.");
		},
		onSettled: () => {
			// Reconcile on both paths: a lost ack (server committed, client saw a
			// network error) or a non-transactional partial delete would otherwise
			// leave onError's restore showing folders the server actually dropped.
			invalidateVaultTree(qc, vaultId);
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folder-notes-by-id", vaultId] });
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
		BatchFoldersContext
	>({
		mutationFn: ({ ids, target_parent }) =>
			api.post<{ moved: number }>(
				"/folders/batch-move",
				// Move by PATH (target_parent) so a derived parent with no marker works.
				{ ids, target_parent },
				idempotencyHeaders(),
			),
		onMutate: async ({ ids, target_parent }) => {
			const foldersKey = ["folders", vaultId] as const;
			await qc.cancelQueries({ queryKey: foldersKey });

			const folders = qc.getQueryData<RawFoldersCache>(foldersKey);
			const ctx: BatchFoldersContext = { folders, noteListSnapshots: [] };
			if (!folders) {
				return ctx;
			}

			// Destination is the parent PATH ('' = top level). Children link to the
			// target's loader id — a real marker id, else the stable `syn:<path>` id a
			// derived parent carries (its raw-cache id is null).
			const targetName = target_parent;
			const targetCacheId =
				target_parent === ""
					? null
					: (folders.folders.find((f) => f.name === target_parent)?.id ??
						syntheticFolderId(target_parent));
			const descendants = collectFolderDescendants(folders.folders, ids);
			// Cycle defense by path: the target is one of the moved folders or sits
			// under one. Skip the optimistic patch and let the server reject (it has
			// the authoritative cycle check). Frontend silence beats lying.
			const movedNames = folders.folders
				.filter((f) => ids.includes(effectiveFolderId(f)))
				.map((f) => f.name);
			if (movedNames.some((n) => target_parent === n || target_parent.startsWith(`${n}/`))) {
				return ctx;
			}

			// Rewrite each moved root: parent_id flips to the target,
			// name path prefix is rebuilt as `${targetName}/${basename}`.
			// Descendants keep their parent_id (still relative to their
			// intra-subtree parent) but their .name prefix is rewritten so
			// the path string stays coherent.
			const idSet = new Set(ids);
			const patched = folders.folders.map<RawFolder>((f) => {
				if (idSet.has(effectiveFolderId(f))) {
					const slash = f.name.lastIndexOf("/");
					const basename = slash < 0 ? f.name : f.name.slice(slash + 1);
					return {
						...f,
						parent_id: targetCacheId,
						name: targetName ? `${targetName}/${basename}` : basename,
					};
				}
				if (descendants.has(effectiveFolderId(f))) {
					// Find the ancestor in the moved set whose name is the
					// longest prefix of `f.name` — that's the root whose path
					// we just rewrote. Compose the descendant's new name by
					// stripping the OLD ancestor prefix and re-attaching the NEW.
					const oldOriginal = folders.folders.find(
						(m) =>
							idSet.has(effectiveFolderId(m)) &&
							(f.name === m.name || f.name.startsWith(`${m.name}/`)),
					);
					if (!oldOriginal) {
						return f;
					}
					const slash = oldOriginal.name.lastIndexOf("/");
					const basename = slash < 0 ? oldOriginal.name : oldOriginal.name.slice(slash + 1);
					const newRoot = targetName ? `${targetName}/${basename}` : basename;
					const tail = f.name === oldOriginal.name ? "" : f.name.slice(oldOriginal.name.length + 1);
					return { ...f, name: tail ? `${newRoot}/${tail}` : newRoot };
				}
				return f;
			});

			qc.setQueryData<RawFoldersCache>(foldersKey, { folders: patched });
			return ctx;
		},
		onError: (_err, _vars, ctx) => {
			if (!ctx) {
				return;
			}
			if (ctx.folders !== undefined) {
				qc.setQueryData(["folders", vaultId], ctx.folders);
			}
			toast.error("Batch move failed.");
		},
		onSettled: () => {
			// Reconcile on both paths: a lost ack (server committed, client saw a
			// network error) leaves onError's restore showing folders the server
			// actually moved until an unrelated refetch.
			invalidateVaultTree(qc, vaultId);
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folder-notes-by-id", vaultId] });
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
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
			qc.invalidateQueries({ queryKey: ["attachments", vaultId] });
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
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
			qc.invalidateQueries({ queryKey: ["attachments", vaultId] });
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
			qc.invalidateQueries({ queryKey: ["folders", vaultId] });
			qc.invalidateQueries({ queryKey: ["folderNotes", vaultId] });
			qc.invalidateQueries({ queryKey: ["attachments", vaultId] });
		},
		onError: () => {
			toast.error("Batch delete failed.");
		},
	});
}
