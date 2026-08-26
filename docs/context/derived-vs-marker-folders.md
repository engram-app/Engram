# Context Doc: Derived (marker-less) folders vs marker folders

_Last verified: 2026-08-25 (Engram PR #1472, merged as `4341fdc3`)_

## Status
Fixed. `DELETE /api/folders/*path` now takes `?recursive=true`, which is what the
web app sends. Marker-only stays the default — the plugin depends on it.

## What This Is

A folder in Engram exists in one of **two shapes**, and almost every folder bug
traces back to code that only ever considered one of them.

**MARKER folder** — a real `notes` row with `kind = "folder"`. It has a real
UUID and appears in `/api/folders` with that id. Two things create one:
- `POST /api/folders` — the web app's "New folder" button.
- The plugin's first-sync seeding, `seedEmptyFolders()` in
  `plugin/src/sync.ts:3427` — one marker per local folder whose **entire subtree
  holds no syncable file**. Without it a truly-empty folder (or one holding only
  `.txt`/`.excalidraw`) would never appear in the web UI.

**DERIVED folder** — **no row at all**. The server reconstructs it from the
`folder` field of the notes inside it. `/api/folders` returns it with a **NULL
id**, and the frontend replaces that with a synthetic `syn:<path>` id
(`frontend/src/viewer/tree/synthesize-folders.ts`). **Every folder Obsidian
creates that contains notes is this shape** — the plugin never POSTs a marker for
it, because `seedEmptyFolders` deliberately skips any folder with a note beneath.

### The third source nobody remembers

`synthesizeFolders(real, attachments)` builds folder rows from **two** caches:
`/api/folders` **and** the attachments cache. A directory holding **only
attachments** is a `syn:` folder sourced purely from `["attachments", vaultId]`
and has no representation in `/api/folders` at all. Any invalidation that only
touches `["folders", vaultId]` leaves that whole folder shape stale.

## The bug (#1472)

`DELETE /api/folders/*path` called `Notes.delete_folder_marker/3`, which clears
only the marker row. For a derived folder there is no marker, so the call
**deleted nothing and returned 204**. Then:

1. `useDeleteFolder`'s optimistic `onMutate` dropped the folder from the tree —
   looked correct.
2. `onSettled` refetched, and the server **re-derived the folder from the notes
   still inside it**.
3. The folder visibly came back after ~1s, and **no note deletes ever reached the
   plugin**.

Folders **with** markers worked fine: `partition()` in
`frontend/src/viewer/folder-tree.tsx:546` routes real ids to
`POST /folders/batch-delete`, which cascades. Only the `syn:` ids fall through to
the path route, one call each.

**The fix:** `?recursive=true` on the path route, dispatching to
`Engram.Folders.delete/4` with `recursive: true` — the same cascade batch-delete
already used. `frontend/src/api/queries.ts` `useDeleteFolder` sends it always,
because that hook only ever deletes derived folders.

**Marker-only must stay the DEFAULT.** The plugin's `handleFolderDelete`
(`plugin/src/sync.ts:3401`) fires only for folders in its `explicitFolders` set,
and Obsidian pushes its own per-note deletes alongside the folder delete. A
recursive default would let the server delete notes the plugin deliberately kept.

## Why three test suites all missed it

The transferable lesson, and the reason this doc exists:

- The **e2e** `delete non-empty folder propagates to a second tab` called
  `createFolder(...)` before deleting — so its folder **always had a marker** and
  **always took the cascade path**.
- **Backend controller tests** did the same (`POST /api/folders` first).
- **Frontend unit tests** mocked the mutation and asserted **the call**, not the
  outcome.

Each suite tested its own half. The seam — *"the web app deletes a folder
Obsidian created"* — belonged to none of them.

> **Rule: if a resource has two construction shapes, a test that only ever builds
> one of them proves nothing about the other.**

The new e2e in `frontend/e2e/tree-ops-sync.spec.ts` builds the folder the derived
way (push notes into a path, never `createFolder`) and asserts **through a
reload**, because the symptom was a *revert* — the optimistic drop looked right
and only the refetch brought it back.

## Gotchas

- **`git diff origin/main` (two-dot) lies on a branch cut before main advanced.**
  It renders the newer main commits as spurious *deletions*. Use
  `git diff origin/main...HEAD`. This misled a code-review agent into reviewing an
  entirely different branch.
- **`BatchOps.broadcast_batch` emits NO log line**
  (`lib/engram_web/controllers/batch_ops.ex:42`). Absence of `folders.batch` in
  the logs is **not** evidence the broadcast didn't fire.
- **A phantom `folders.batch` delete broadcast is cheap and safe.** The plugin's
  handler ignores the payload entirely: `resyncFolders()` → `syncExplicitFolders()`
  re-polls `GET /folders/explicit` and trashes only a folder the server no longer
  lists **that is also empty on disk**. One extra GET, not a lost local folder.
  Do **not** add a guard that suppresses the broadcast to "avoid a phantom" — one
  was added and removed in review, because it swallowed real deletes: a nested
  empty marker reports `notes: 0`, indistinguishable from "nothing was there".
- **Query params are never cast in this pipeline.** Declaring a param
  `type: :boolean` in the OpenAPI operation while the code compares
  `params["x"] == "true"` means `?x=1` **silently no-ops** — a 204 on a
  destructive endpoint that deleted nothing. Convention here is `type: :string`
  with the accepted literals spelled out in the description (see the `?raw` param
  on the attachments controller).
- **Any new delete path must invalidate the attachments cache too.** See "third
  source" above — otherwise the recursive delete removes the attachment
  server-side while the stale cache keeps re-deriving the folder, reproducing the
  exact revert for a different folder shape.

## Failed approaches / local-environment traps

- **Running Playwright while `make dev-selfhost` is up.** `reuseExistingServer:
  !isCI` makes the suite **reuse that server**, which is invite-gated, so every
  test dies on `register failed: 403 invite_required`. Stop the dev stack first.
- **`rename note propagates` / `rename folder propagates`** in
  `frontend/e2e/tree-ops-sync.spec.ts` fail on this dev box against **pristine
  origin/main** with `Protocol error (Runtime.callFunctionOn): session closed`.
  They pass on CI. Do not chase them as regressions — see
  `docs/context/headless-chromium-no-raf-playwright.md`.

## References

- PR #1472 — `4341fdc3` `fix(folders): web delete of a populated folder removes its contents`
- `lib/engram_web/controllers/folders_controller.ex` — `delete/2`, `truthy?/1`, `delete_recursive/4`
- `lib/engram/folders.ex` — moduledoc documents both DELETE paths
- `frontend/src/viewer/tree/synthesize-folders.ts` — the `syn:<path>` id scheme
- `frontend/src/viewer/folder-tree.tsx:546` — `partition()`, marker vs derived dispatch
- `frontend/src/api/queries.ts` — `useDeleteFolder`
- `plugin/src/sync.ts` — `handleFolderDelete` (3401), `seedEmptyFolders` (3427), `syncExplicitFolders` (8312)
- `docs/context/crdt-create-is-a-rename.md` — the same "one route serves two meanings" trap on the note side
- `docs/context/folder-tree-optimistic-rebuild.md` — optimistic tree updates + rebuild triggers
- `docs/context/headless-chromium-no-raf-playwright.md` — local Playwright/Chromium flakes
