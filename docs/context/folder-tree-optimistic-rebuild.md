# Context Doc: Web SPA Folder-Tree Optimistic Updates + Rebuild Triggering

_Last verified: 2026-09-10_

## Status
Working. Core paths fixed 2026-06-13; the GC eviction that flashed the tree
empty was fixed 2026-09-10 by deleting the cache it lived in (#1601), which
also collapsed the four note-list caches into one. Two duplicated-state gaps
remain (see Gotchas).

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
- `frontend/src/api/queries.ts` — the one `['vault-tree']` query, its `select` views, and mutation hooks w/ optimistic `onMutate`
- `frontend/src/api/vault-tree-patch.ts` — pure tree edits the `onMutate`s apply

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
explicit **`rebuildTree()`**. It does NOT react to cache writes, so
`use-engram-tree.ts` triggers the rebuild itself.

Since #1601 that is ONE mechanism: a `useEffect` on the memoized loader, which
changes identity exactly when one of its inputs (`folders`, `notes`,
`attachments`, `sort`) does. Those are all `select` views of the one vault-tree
query, and react-query keeps a select result referentially stable until the
underlying data actually changes — including across a refetch that returns the
same bytes, via structural sharing. So `!==` is a complete and exact answer to
"does the tree need redrawing".

**Historical (pre-#1601), because the shape recurs:** there used to be two
mechanisms — a `treeStructureKey` fingerprint over `id:count:parent_id` plus
sort, and a QueryCache subscription that rebuilt on any `folder-notes-by-id`
write. Both existed because the per-folder caches handed out a fresh array on
every no-op refetch, so identity told you nothing and the subscription needed
its own content fingerprint (sorted `id:version:path:updated_at:created_at`
over every note) just to tell a real change from a redundant one. The structure
key also had a standing blind spot: it never saw note-list *contents*, so a
note op that changed no folder count would not redraw through it. Collapsing
the caches removed the blind spot and the fingerprint together.

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

**First fix (shipped, then superseded):** `gcTime: Number.POSITIVE_INFINITY` on
`folderNotesByIdQueryOptions`. It stopped the bleeding in one line and did not
touch the reason an observerless entry existed at all.

**Actual fix (#1601):** the entry was deleted. `useFolders`, `useAttachments`,
`useVaultNotes` and `useFolderNotesById` are now `select` VIEWS of the one
`['vault-tree', vaultId]` query, not caches of their own, and the tree loader
is a pure function of the arrays the component already holds. A view of an
observed query cannot be collected out from under its reader, so the failure
mode is gone rather than suppressed. `['folder-notes-by-id']` no longer exists
— do not go looking for it.

There is no standalone regression test for the GC behaviour any more, because
the cache it guarded is gone. The shape it would have needed is still worth
knowing: fetch with **no observer**, advance fake timers past `gcTime`, assert
the data survives — and never mount a hook in it, or it proves nothing.

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
- **Historical (pre-#1601): `folder-notes-by-id` queries had NO `useQuery`
  observers.** The loader read them via `getQueryData` and seeded via
  `prefetchQuery` / `fetchQuery`, so `invalidateQueries` marked them stale but
  did NOT auto-refetch — they only refreshed on the next folder expand, which is
  why `onSuccess` invalidation alone didn't update the tree and why the channel
  needed `refetchType: "all"`. Both consequences of observerlessness, the stale
  read and the `gcTime` eviction, were the same root cause. Kept here because
  the *class* recurs; the specific cache does not exist any more.

### Deliberately NOT consolidated
- **`['folderNotes', vaultId, folder]` (`/folders/list`) stays a second copy**
  for the dashboard. That screen renders tags, and tags are ENCRYPTED
  (`tags_ciphertext`), so adding them to `/vault/tree` means a second per-note
  decrypt across the whole vault — the exact cost VaultTreeController's
  moduledoc says the thin tree payload exists to avoid. Don't "finish the
  consolidation" here without measuring that.
- **`GET /api/folders` stays** — the plugin calls it. `/folders/list` and
  `GET /api/attachments` have no web caller left but are public REST surface.

### How sync events reach the tree (#1601)
`api/channel.ts` coalesces `note_changed` events for 250 ms and applies them to
the tree in one pass (`applyNoteEvents` in `vault-tree-patch.ts`) instead of
re-downloading the vault. It re-fetches instead only when a patch can't be
trusted: an attachment event (`kind: "attachment"`, no id), a folder-marker
delete (no id), no tree cached, a tree fetch already in flight (its older
response would land on top of the patch), or **any note moving to a different
folder**. That last one is the non-obvious one: `rename_folder` broadcasts one
upsert+delete pair per note and NOTHING about the folder marker, so a patch
moves the notes but leaves the old marker listed (markers survive empty). A
plain move out of a marker folder looks identical on the wire and there the
marker should stay — the client can't distinguish them, so it asks the server.
Caught by e2e `tree-ops-sync.spec.ts` "rename folder propagates to a second
tab". If the backend ever emits a `folders.batch` rename event, this fallback
can narrow to just that event. Deletes are path-guarded because a
rename is `delete(old) + upsert(new)` with one id in no fixed order.

Folder rows are re-derived from notes after every edit, matching the server:
markers always listed, derived folders listed iff a note is filed in them. A
note arriving in a never-seen folder therefore gets a row, and a derived folder
whose last note leaves disappears immediately rather than on the next fetch.

**Contract that bites in tests:** the tree rebuilds on reference identity of
its inputs. Any stub of `useFolders`/`useVaultNotes`/`useAttachments` that
returns a fresh array per call makes it rebuild forever — a hang, not a
failure. It hung the whole frontend CI job for 96 minutes once. Hoist the
stub's array.

## References
- `frontend/src/api/queries.ts` (`vaultTreeQueryOptions` and the `select` views over it; `snapshotTree`/`patchTree`/`restoreTree`)
- `frontend/src/api/vault-tree-patch.ts` (the pure optimistic edits, and why `count` is recomputed rather than adjusted)
- `frontend/src/viewer/tree/loader.ts` (pure; `folderChildren`, `rootChildren`, `noteChildItems`)
- `frontend/src/viewer/tree/use-engram-tree.ts` (rebuild keyed on loader-input identity)
- Related: `docs/context/perf-caching-invalidation.md`
