# Frontend file-tree: the two caches, the `select` seam, and the virtualizer

Three traps in the SPA's file tree that each produced a user-visible bug during
the 2026-07-26 tree overhaul (#1121). They look unrelated; two of them are the
same underlying shape. Written down because none of them fail loudly — every
one degrades into a plausible-looking "not cached yet" or "correct heights" and
stays silent.

## 1. There are TWO note-list caches, and the tree renders the second

| Key | Shape | Who reads it |
|---|---|---|
| `['folderNotes', vaultId, folderPath]` | `{ notes: NoteSummary[] }` | dashboard / folder-browse view |
| `['folder-notes-by-id', vaultId, folderId]` | `NoteSummary[]` (bare array) | **the sidebar tree** |

Note they differ in **both** the key (path vs id) and the payload shape
(wrapped vs bare).

A mutation that optimistically updates only the path-keyed lists looks complete
and tests green, but the sidebar still lags a full refetch behind. This caused
three separate bugs in one session:

- rename updated the path-keyed lists, so the tree row kept the old name;
- note-create didn't invalidate the id-keyed list when the folder wasn't cached;
- the note-body cache (`['note', vaultId, id]`) was a third place again.

**Rule:** when adding or auditing an optimistic write for notes, ask which of
the caches you touched, and check the id-keyed one specifically — it's the one
the user is looking at. Rollback needs a snapshot of *each* list you touched
(see `RenameNoteContext.byIdLists`), not a recomputed inverse: reversal breaks
if two mutations overlap.

## 2. `getQueryData` returns PRE-`select` data

`useFolders()` fetches `{ folders: Array<Folder & { id: string | null }> }` and
applies `select: selectFolders`, which is what maps a **derived** folder's
`id: null` to a stable `syn:<path>` id.

`select` transforms what the *observer* sees. It does **not** transform the
cache. So any helper reading `qc.getQueryData(['folders', vaultId])` sees the
raw payload, nulls included.

`folderIdForPath` did exactly that and returned the raw `id` — `null` for most
real folders. Every caller reads null as "unknown folder, skip the optimistic
patch", so creating a note in a folder silently did nothing until reload. The
fix is to apply the same null → `syn:<path>` mapping `selectFolders` does.

**Rule:** a helper reading `getQueryData` for a query that has a `select` must
re-apply that select's normalisation, or read through the hook instead. This
fails silently precisely because "no id yet" is a legitimate state.

### Related: "derived" folders are most folders

`/api/folders` returns any folder that holds no note **directly** with a null
id. In a vault whose top level is mostly containers, that's nearly all of them.
Code that treats `syn:` ids as a rare edge case will mis-handle the common path
— this is what made the folder context menu fall through to the browser's.

Derived folders have no id, but they do have a path, and the path-based routes
cover everything the id-keyed batch endpoints do:

| Action | id-keyed | path-based equivalent |
|---|---|---|
| rename | — | `POST /folders/rename {old_path,new_path}` |
| delete | `POST /folders/batch-delete {ids}` | `DELETE /folders/*path` |
| move | `POST /folders/batch-move {ids}` | a rename into the new parent |

So "it has no id" is never a reason to hide an action — only a reason to pick a
different route.

## 3. `estimateSize` is authoritative unless you attach `measureElement`

`@tanstack/react-virtual` has two modes, and the difference is easy to miss:

- **With** `virtualizer.measureElement` on each row: the estimate is a
  first-paint guess, corrected per row via `ResizeObserver`.
- **Without** it: the estimate is treated as truth. Rows are positioned at
  `index * estimateSize`, permanently.

The tree was in the second mode with `estimateSize: () => 24`, while rows
actually rendered **28px** (`text-base` = 24px line-height, plus `py-0.5`).
Every row overflowed its neighbour by 4px, which is what made hover fills
overlap.

Adding `measureElement` fixes the heights but is not free: it reads geometry as
each row mounts, so expanding a folder (a screenful at once) becomes a
layout-thrash loop. A trace showed **60ms of forced reflow** on a single
expand, which janked the chevron transition it was meant to help.

Resolution: rows are uniform, so they don't need measuring — they need a height
that provably matches the slot. `viewer/tree/row-metrics.ts` owns both numbers
(`TREE_ROW_HEIGHT`, `TREE_ROW_GAP`, `TREE_SLOT_HEIGHT`); `estimateSize` returns
the slot height exactly and `TreeRow` pins itself to the row height. Reflow went
56ms → 4ms.

**Rule:** pinned heights are right for a uniform list, but the constant and the
CSS must have a single source. If rows ever become genuinely variable-height,
switch to `measureElement` — and re-measure the expand interaction, because
that's the cost you're buying back.

### Corollary: the indent guides

Guides are absolutely positioned inside the row, so two things follow from the
pinned geometry:

- they need `-inset-y-px`, not `inset-y-0`, or the line breaks at every gutter;
- `left` positions the span's **edge**, so a 1px line must be offset by half its
  width to sit on the chevron's centre. Invisible at one line, obvious at five.

## Why measuring mattered

Both geometry bugs survived two rounds of plausible-sounding guesses and were
identified in minutes with a CDP performance trace (the `mcp__cdp-laptop__`
tools against the running dev server). Unit tests cannot catch either one:
jsdom reports zero heights, so the entire class of layout bug is invisible to
`bun run test`.

If a tree/layout symptom is described as "janky", "off by a pixel", or "worse
the deeper you go", trace it before theorising. A trace also disambiguates a
*constant* error from a *cumulative* one — the guides felt cumulative and were
constant, which pointed at the wrong fix twice.

## See also

- `frontend/src/viewer/tree/row-metrics.ts` — geometry constants + why we don't measure
- `frontend/src/api/queries.ts` — `folderIdForPath`, `realFilenames`, `RenameNoteContext`
- `frontend/src/viewer/tree/synthesize-folders.ts` — `syn:` id scheme
- PR #1121 — where all of this was found
