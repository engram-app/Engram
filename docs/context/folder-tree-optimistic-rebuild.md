# Context Doc: Web SPA Folder-Tree Optimistic Updates + Rebuild Triggering

_Last verified: 2026-06-13_

## Status
Working — core paths fixed 2026-06-13. Two known optimistic gaps remain (see Gotchas).

## What This Is
How the React SPA's left-rail folder tree builds its hierarchy from React Query
caches, and how/when it forces the headless-tree library to recompute its flat
item list so optimistic note/folder ops appear without a manual refresh.

## Environment
`backend/frontend/` (React + TS + Vite). Library: `@headless-tree/core` +
`@headless-tree/react`. Files:
- `frontend/src/viewer/tree/use-engram-tree.ts` — the hook + rebuild triggers
- `frontend/src/viewer/tree/loader.ts` — hierarchy + note-list reads
- `frontend/src/viewer/folder-tree.tsx` — wiring (data sources, mutation hooks)
- `frontend/src/api/queries.ts` — mutation hooks w/ optimistic `onMutate`

## How It Works

### headless-tree is headless
We use `dragAndDropFeature` for the **drag gesture + drop hit-testing only**.
`canReorder: false`. `onDrop(items, target)` hands us the source items + the
destination container; **we own persistence** via the batch mutation hooks
(`onMove` → `useBatchMoveNotes`). The library never mutates our data — it only
keeps a derived flat item list.

### Where the loader reads data (`loader.ts`)
- **Folder hierarchy**: built from the `folders` cache (`parent_id` / `name`;
  `name` IS the full path, leaf is `name.split('/').pop()`).
- **Subfolder notes**: from `['folder-notes-by-id', vaultId, folderId]` (by-id cache).
- **Root notes**: from `deps.rootNotes` = `useFolderNotes('')` = the legacy
  path-keyed `['folderNotes', vaultId, '']` cache (the by-id endpoint requires a
  non-null folder id, so root can't use it).

### When headless-tree recomputes
HT only rebuilds its flat list on: **mount**, **expandedItems change**, or an
explicit **`rebuildTree()` / `invalidateChildrenIds()`**. It does NOT react to
cache writes. So we trigger rebuilds ourselves via two mechanisms in
`use-engram-tree.ts`:

1. **`treeStructureKey(folders, rootNoteIds, sort)`** → a `useEffect` that calls
   `rebuildTree()` when the key changes. Fingerprints each folder as
   `id:count:parent_id`, plus root note ids, plus sort. Keyed (not identity) so
   spurious churn doesn't spin a max-update-depth loop.
   **Blind spot**: it does NOT see `folder-notes-by-id` list *contents*. A note
   op that changes a by-id list without changing any folder count/parent_id will
   NOT rebuild via the key alone.
2. **QueryCache subscription** → the same hook subscribes to the query cache and
   calls `rebuildTree()` (coalesced via `queueMicrotask` so a batch op that
   patches many lists fires one pass) whenever a `['folder-notes-by-id', vaultId, *]`
   query is `added` / `removed` / `updated`-with-`success`. This is the general
   safety net for by-id list changes the structure key misses.

## The Bug Class We Fixed (2026-06-13)
Optimistic note move/delete/duplicate didn't show in the tree until manual
refresh or folder collapse/expand. Four distinct causes, four fixes:

- **(a) Folder move** changed `parent_id` but the old key only had `id:count` →
  added `parent_id` to `treeStructureKey`.
- **(b) Note move** updated by-id lists but not folder counts → `useBatchMoveNotes.onMutate`
  now bumps folder `count`s (source folders decrement, target increments) so the
  structure key flips.
- **(c) Batch delete** updated by-id lists with no count change → fixed
  GENERALLY by the QueryCache subscription (rebuild on any by-id change).
- **(d) Duplicate** wrote only legacy `['folderNotes', folder]`, but the tree
  reads by-id for subfolders → `useDuplicateNote.onMutate` now mirrors the
  placeholder into `['folder-notes-by-id', vaultId, targetFolder.id]` too.

## Failed Approaches / Dead Ends
- **`onSuccess` invalidation alone** does NOT refresh the tree for by-id lists —
  see the observer gotcha below. The optimistic `onMutate` patch + a rebuild
  trigger is what makes it appear; invalidation only reconciles later, on the
  next loader read.
- **Suspecting `cancelQueries` / AbortSignal as the delay source** — investigated
  and ruled out. React Query awaits `onMutate` before `mutationFn`, measured
  optimistic paint was ~35ms. The delay was the missing rebuild, not cancellation.

## Gotchas
- **`api.get<T>(path)` does NOT forward an AbortSignal** (only `post`/etc. take a
  `signal` opt). So GET queries are not cancellable — `qc.cancelQueries` cannot
  abort an in-flight GET. (Optimistic writes in `onMutate` run after
  `await cancelQueries`; harmless here per the dead-end above.)
- **`folder-notes-by-id` queries have NO `useQuery` observers.** The loader reads
  them via `getQueryData` and seeds via `prefetchQuery` / `fetchQuery`. So
  `invalidateQueries` marks them stale but does NOT auto-refetch them — they only
  refetch on the next loader read (folder expand). This is exactly why
  `onSuccess` invalidation alone didn't refresh the tree.

### Known remaining gaps (NOT yet fixed)
- **Root-note batch delete**: `useBatchDeleteNotes` only patches `folder-notes-by-id`
  lists. Root notes live in `folderNotes['']`, so a deleted root note does NOT
  disappear optimistically.
- **`useCreateNote` has no optimistic insert** — relies on
  navigate → auto-expand → fresh fetch to surface the new note.

## References
- `frontend/src/viewer/tree/use-engram-tree.ts` (`treeStructureKey`, the two rebuild effects)
- `frontend/src/viewer/tree/loader.ts` (`folderChildren`, `rootChildren`, `noteLoaderItem`)
- `frontend/src/viewer/folder-tree.tsx` (data sources + `fetchFolderNotes` wiring)
- `frontend/src/api/queries.ts` (`useBatchMoveNotes`, `useBatchDeleteNotes`, `useDuplicateNote`, `useCreateNote`)
- Related: `docs/context/perf-caching-invalidation.md`
