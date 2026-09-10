# Context Doc: Web SPA Folder-Tree Optimistic Updates + Rebuild Triggering

_Last verified: 2026-09-10_

## Status
Working — core paths fixed 2026-06-13, GC eviction fixed 2026-09-10. Two known
optimistic gaps remain (see Gotchas).

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

1. **`treeStructureKey(folders, sort)`** → a `useEffect` that calls
   `rebuildTree()` when the key changes. Fingerprints each folder as
   `id:count:parent_id`, plus sort (the call site also concatenates an
   `attachmentsFingerprint(...)` onto the result). Keyed (not identity) so
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

## A cache entry read without a hook has NO observer — so `gcTime` deletes it (2026-09-10)

**The durable lesson, and it is not tree-specific:** a React Query entry that a
component reads with `qc.getQueryData` / fills with `qc.fetchQuery` — instead of
subscribing through `useQuery` — has **no observer**. React Query garbage-collects
any observerless query after `gcTime` (default **5 minutes**). Nothing warns you:
the read still compiles, still type-checks, and works for the first five minutes
of every session. And when the same component *also* rebuilds itself off a
QueryCache subscription, the GC deletion is not a silent cache miss — it is a
**visible flash of missing data**.

Symptom that led here: the sidebar file tree periodically flashed empty. A
folder's notes vanished for many seconds every few minutes; folders looked like
they collapsed and reopened on their own.

The loop, all four steps required:

1. `loader.ts` (`noteChildItems`) reads `['folder-notes-by-id', vaultId, folderId]`
   with `getQueryData` and fills a miss with `fetchQuery` — **no observer**.
2. Only the ROOT list has one (`folder-tree.tsx:75`, `useFolderNotesById(ROOT_FOLDER_ID)`),
   so every **expanded subfolder's** list is observerless and hits the default
   5-minute `gcTime`.
3. `use-engram-tree.ts` subscribes to the QueryCache and calls `rebuildTree()` on a
   `removed` event — i.e. the eviction itself *triggers* a rebuild.
4. The rebuild re-runs `getChildren`, the loader now misses, and the folder renders
   with **only its subfolders**. The notes return only after `fetchQuery` →
   `fetchVaultTree` → a full `/vault/tree` round trip, which `fetchVaultTreeFresh`
   can retry up to 3 extra times when sync-channel invalidations land mid-flight.
   Hence the multi-second gap, not a blink.

**Fix:** `gcTime: Number.POSITIVE_INFINITY` on `folderNotesByIdQueryOptions`
(`frontend/src/api/queries.ts`). Immortal is correct *here* specifically because
these rows are a derivation of the one vault tree we already keep resident, they
are keyed by vault, and the whole cache is dropped on a user change
(`useClearQueryCacheOnUserChange`) — so the entries cannot outlive their tenant.

Regression test: `frontend/src/api/folder-notes-gc.test.ts` — fetches with **no
observer**, advances fake timers 10 minutes, asserts the data is still cached.
Note the shape: the test must never mount a hook, or it proves nothing.

**Rule for new query options:** decide the observer question explicitly. If any
caller reaches the entry through `getQueryData`/`fetchQuery`, either give it a
non-default `gcTime` or give it a real observer. Do not leave it on the default
and assume "it's cached". The two consequences of observerlessness are separate
and you own both: **`invalidateQueries` won't refetch it** (see the Gotchas
below) and **`gcTime` will delete it**.

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
  `onSuccess` invalidation alone didn't refresh the tree. The *other* consequence
  of having no observer — `gcTime` evicting the entry outright — is the 2026-09-10
  section above; they are the same root cause with two different symptoms.

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
- `frontend/src/api/queries.ts` (`folderNotesByIdQueryOptions` + its `gcTime`, `useBatchMoveNotes`, `useBatchDeleteNotes`, `useDuplicateNote`, `useCreateNote`)
- `frontend/src/api/folder-notes-gc.test.ts` (observerless-survival regression test)
- Related: `docs/context/perf-caching-invalidation.md`
