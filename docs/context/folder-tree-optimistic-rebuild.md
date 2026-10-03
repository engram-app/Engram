# Context Doc: Web SPA Folder Tree (cache, rebuild, optimistic updates, virtualizer)

_Last verified: 2026-10-03_

## Status
Working. Since #1601 (2026-09-10) the tree reads ONE cache, `['vault-tree', vaultId]`.

## What This Is
How the React SPA's left-rail folder tree gets its data, when it forces the
headless-tree library to recompute, how optimistic ops and sync events patch it,
and the traps in each. None of these fail loudly.

## Environment
`frontend/` (React + TS + Vite). Library: `@headless-tree/core` +
`@headless-tree/react`, rows virtualized with `@tanstack/react-virtual`. Files:
- `frontend/src/viewer/tree/use-engram-tree.ts`: the hook, rebuild trigger, virtualizer
- `frontend/src/viewer/tree/loader.ts`: pure hierarchy + note-list reads
- `frontend/src/viewer/tree/row-metrics.ts`: row geometry constants
- `frontend/src/viewer/tree/synthesize-folders.ts`: `syn:<path>` id scheme
- `frontend/src/viewer/folder-tree.tsx`: wiring (data sources, mutation hooks)
- `frontend/src/api/queries.ts`: `vaultTreeQueryOptions`, its `select` views, mutation hooks with optimistic `onMutate` (`snapshotTree`/`patchTree`/`restoreTree`)
- `frontend/src/api/vault-tree-patch.ts`: pure tree edits used by `onMutate` and sync events

## How It Works

### One cache, many views
`useFolders`, `useAttachments`, `useVaultNotes` and `useSyncManifest` are
`select` views of `['vault-tree', vaultId]`, not caches of their own. The tree
loader is a pure function of the arrays the component already holds, and every
optimistic mutation patches that one entry.

### headless-tree is headless
We use `dragAndDropFeature` for the **drag gesture + drop hit-testing only**.
`canReorder: false`. `onDrop(items, target)` hands us the source items + the
destination container; **we own persistence** via the batch mutation hooks.
The library never mutates our data; it only keeps a derived flat item list.

### When headless-tree recomputes
HT only rebuilds its flat list on **mount**, **expandedItems change**, or an
explicit **`rebuildTree()`**. It does NOT react to cache writes, so
`use-engram-tree.ts` triggers the rebuild with a `useEffect` on the memoized
loader, which changes identity exactly when one of its inputs (`folders`,
`notes`, `attachments`, `sort`) does. react-query keeps a select result
referentially stable until the underlying data changes, including across a
refetch that returns the same bytes (structural sharing). So `!==` is a
complete and exact answer to "does the tree need redrawing".

**Contract that bites in tests:** any stub of `useFolders`/`useVaultNotes`/
`useAttachments` that returns a fresh array per call makes the tree rebuild
forever: a hang, not a failure. It hung the frontend CI job for 96 minutes
once. Hoist the stub's array.

### How sync events reach the tree
`api/channel.ts` coalesces `note_changed` events for 250 ms
(`BATCH_WINDOW_MS`); `queries.ts` applies the batch in one pass
(`applyNoteEvents` in `vault-tree-patch.ts`) instead of re-downloading the vault. It re-fetches
instead when a patch can't be trusted: an attachment event (`kind:
"attachment"`, no id), a folder-marker delete (no id), no tree cached, a tree
fetch already in flight (its older response would land on top of the patch), or
**any note moving to a different folder** (`movesAcrossFolders`). That last one
is the non-obvious one: `rename_folder` broadcasts one upsert+delete pair per
note and NOTHING about the folder marker, so a patch moves the notes but leaves
the old marker listed (markers survive empty). A plain move out of a marker
folder looks identical on the wire and there the marker should stay; the client
can't distinguish them, so it asks the server. Caught by e2e
`tree-ops-sync.spec.ts` "rename folder propagates to a second tab". The move is
detected from the rename's DELETE leg too (it carries the old path), because a
CRDT-origin create broadcasts no `note_changed`, so the tree often doesn't know
the note. If the backend ever emits a `folders.batch` rename event, this
fallback can narrow to just that event.

It also re-fetches instead of patching while a refetch is **owed**: the tree is
`isInvalidated` or in `error`. `setQueryData` marks the entry fresh, so a patch
there would silently cancel the owed refetch. Deletes are path-guarded because
a rename is `delete(old) + upsert(new)` with one id in no fixed order.

Folder rows are re-derived from notes after every edit, matching the server:
markers always listed, derived folders listed iff a note is filed in them.

## Traps

### A cache entry read without a hook has NO observer, so `gcTime` deletes it
Not tree-specific. A React Query entry that a component reads with
`qc.getQueryData` / fills with `qc.fetchQuery` instead of `useQuery` has **no
observer**. React Query garbage-collects any observerless query after `gcTime`
(default **5 minutes**), and `invalidateQueries` marks it stale but does NOT
refetch it. Nothing warns you. Before #1601 this made the sidebar flash empty
every few minutes: a QueryCache subscription rebuilt the tree on the `removed`
event, and the rebuild then missed the evicted per-folder list.

**Rule for new query options:** decide the observer question explicitly. If any
caller reaches the entry through `getQueryData`/`fetchQuery`, either give it a
non-default `gcTime` or a real observer. A regression test for this must fetch
with **no observer**, advance fake timers past `gcTime`, and assert the data
survives; mounting a hook in it proves nothing.

### `getQueryData` returns PRE-`select` data
`useFolders()` applies `select: selectFolders`, which maps a **derived**
folder's `id: null` to a stable `syn:<path>` id. `select` transforms what the
*observer* sees, not the cache. Any helper reading
`qc.getQueryData(['vault-tree', vaultId])` sees the raw payload, nulls
included. A helper that did exactly that returned `null` for most real folders,
every caller read null as "unknown folder, skip the optimistic patch", and
creating a note in a folder silently did nothing until reload.

**Rule:** a helper reading `getQueryData` for a query that has a `select` must
re-apply that select's normalisation, or read through the hook.

### Derived folders are most folders
The wire gives a folder a null id when it has **no marker row**: it is listed
only because notes are filed directly in it. A folder with a marker carries the
marker's id (and is listed even when empty); a pure container of sub-folders is
not on the wire at all and is synthesized client-side. Code that treats `syn:`
ids as a rare edge case mis-handles the common path (this is what made the
folder context menu fall through to the browser's).

"It has no id" is never a reason to hide an action, only to pick a different
route:

| Action | id-keyed | path-based equivalent |
|---|---|---|
| rename | none | `POST /folders/rename {old_path,new_path}` |
| delete | `POST /folders/batch-delete {ids}` | `DELETE /folders/*path` |
| move | `POST /folders/batch-move {ids}` | a rename into the new parent |

### Optimistic rollback: snapshot, don't invert
Rollback restores a snapshot of what was patched (`snapshotTree`/`restoreTree`),
not a recomputed inverse: reversal breaks if two mutations overlap.

### `estimateSize` is authoritative unless you attach `measureElement`
`@tanstack/react-virtual` has two modes. **With** `virtualizer.measureElement`
on each row, the estimate is a first-paint guess corrected via
`ResizeObserver`. **Without** it, rows are positioned at `index *
estimateSize`, permanently. The tree once had `estimateSize: () => 24` while
rows rendered 28px, so every row overflowed its neighbour by 4px.

`measureElement` fixes heights but reads geometry as each row mounts, so
expanding a folder became a layout-thrash loop (60ms forced reflow on one
expand). Rows are uniform, so `row-metrics.ts` owns the numbers
(`TREE_ROW_HEIGHT`, `TREE_ROW_GAP`, `TREE_SLOT_HEIGHT`), `estimateSize` returns
the slot height exactly, and `TreeRow` pins itself to the row height. Reflow
went 56ms to 4ms. If rows ever become variable-height, switch to
`measureElement` and re-measure the expand interaction.

Indent guides are absolutely positioned inside the pinned row: they need
`-inset-y-px`, not `inset-y-0`, or the line breaks at every gutter; and `left`
positions the span's edge, so a 1px line must be offset by half its width to
sit on the chevron's centre.

**Measure layout bugs, don't theorise.** jsdom reports zero heights, so unit
tests cannot see this class. Both geometry bugs survived two rounds of guesses
and fell in minutes to a CDP performance trace. A trace also tells a constant
error from a cumulative one.

## Failed Approaches / Dead Ends
- **`onSuccess` invalidation alone** for optimistic tree ops. The optimistic
  `onMutate` patch is what makes the change appear; invalidation only
  reconciles later.
- **Suspecting `cancelQueries` / AbortSignal as the delay source.** Ruled out:
  React Query awaits `onMutate` before `mutationFn`; measured optimistic paint
  was ~35ms.

## Gotchas
- **`api.get<T>(path)` does NOT forward an AbortSignal** (only `post`/etc. take
  a `signal` opt), so `qc.cancelQueries` cannot abort an in-flight GET.

### Deliberately NOT consolidated
- **`['folderNotes', vaultId, folder]` (`/folders/list`) stays a second copy**
  for the dashboard. That screen renders tags, and tags are ENCRYPTED
  (`tags_ciphertext`), so adding them to `/vault/tree` means a second per-note
  decrypt across the whole vault, the cost the thin tree payload exists to
  avoid. Don't "finish the consolidation" here without measuring that.
- **`GET /api/folders` stays**: the plugin calls it. `GET /api/attachments`
  has no web caller but is public REST surface.

## References
- `frontend/src/api/queries.ts`, `frontend/src/api/vault-tree-patch.ts`
- `frontend/src/viewer/tree/` (`loader.ts`, `use-engram-tree.ts`, `row-metrics.ts`, `synthesize-folders.ts`)
- PRs #1121 (tree overhaul, virtualizer), #1601 (one cache)
- Related: `docs/context/perf-caching-invalidation.md`
