# Folder rename/delete attachment cascade + MCP move tool

**Date:** 2026-06-23
**Branch:** `fix/folder-attachment-cascade`
**Status:** design approved (brainstorming) — pending spec review

## Problem

A folder rename or delete only touches `notes` rows. Attachments live in a
separate `attachments` table keyed by an encrypted `path` (no `folder` column).
So:

- `Engram.Notes.rename_folder/4` moves note rows but **leaves attachments
  stranded at their old paths** — orphaned in the DB and in every synced client.
- `Engram.Notes.delete_folder/3` (via `do_delete_folders/3`) soft-deletes note
  rows but **leaves attachments live** under a folder the user deleted.

Both are silent: no error, the operation reports success, the orphan just
lingers. Confirmed by reading `notes.ex:2245` (rename cascade) and
`notes.ex:2452` (delete cascade) — both query only `Note`.

A secondary gap: the MCP surface exposes `rename_note` / `rename_folder` but has
**no tool to move/rename a single attachment**, even though
`Engram.Attachments.move_attachment/4` already exists and is wired to REST.

## Goals

1. Folder **rename** moves the folder's attachments too (incl. nested subfolders).
2. Folder **delete** soft-deletes the folder's attachments too.
3. Add an MCP `move_attachment` tool wrapping the existing context function.

## Non-goals

- No new `folder` column / `folder_hmac` on attachments. Attachment paths are
  encrypted; folder membership is derived by decrypt-then-prefix-match, exactly
  like notes already do (`do_rename_folder` / `do_delete_folders`).
- No unified cross-table transaction (see "Transaction boundary" below).
- No change to attachment blob/storage handling — path is metadata, the S3
  object is content-addressed and never moves on rename (unchanged behavior).

## Design

### Where the cascade lives

Attachment crypto / AAD / tombstone logic belongs to `Engram.Attachments` (it
already owns `move_attachment/4`, the single-item template). Add two functions
there, each mirroring an existing pattern:

- `Attachments.rename_folder(user, vault, old_folder, new_folder) :: {:ok, count} | {:error, :conflict | term()}`
  - Fetch live attachments + decrypt paths (reuse the `list_attachments/2`
    decrypt path).
  - Prefix-filter: `path == old_folder` is impossible (attachments are files),
    so match `String.starts_with?(path, old_folder <> "/")`.
  - Compute `new_path = new_folder <> rest` where `rest = String.slice(path, len(old_folder)..)`.
  - **Conflict pre-check:** if any computed `new_path` already exists live
    (by `path_hmac`), return `{:error, :conflict}` before mutating anything.
  - In **one transaction under one seq** (`Engram.Vaults.next_seq!/1`): per
    attachment, re-encrypt `path` under its **own unchanged id-AAD**
    (`Crypto.aad_for_row(:attachments, :path, id)` — id is stable so the AAD
    bind is unchanged, same as `move_attachment`), recompute `path_hmac`, bump
    `seq` + `updated_at`; then insert an old-path tombstone per row (same
    `tombstone_changeset` helper) at the **same seq**.
  - Broadcast `delete` (old path) + `upsert` (new path) per attachment, outside
    the txn (matches `move_attachment` + `rename_folder`).

- `Attachments.delete_folder(user, vault, folder) :: {:ok, count}`
  - Same fetch + prefix-filter.
  - Reuses `batch_delete/3` over the matched paths (DRY — one delete path, not a
    bespoke `update_all`). Each soft-delete allocates its **own per-item seq** via
    `Engram.Vaults.next_seq!/1`. **No tombstone** — the soft-deleted row itself
    becomes the delete signal (mirrors `do_delete_folders`, where the
    soft-deleted note row IS the tombstone).
  - **Per-item seq is safe for deletes** (deliberately diverges from a literal
    "one seq per op"): the #614 same-seq invariant (a cursor pull must not see a
    moved row at seq S, advance past S, and miss its same-seq tombstone) only
    applies to **rename**, which pairs a repointed row with a same-seq tombstone.
    Delete has no tombstone, so there is no same-seq pair to keep together; each
    soft-deleted row stands alone as its own change signal at its own seq.
  - Cross-item + cross-table atomicity comes from the `Engram.Folders`
    coordinator's `atomic/1` wrapper (a mid-loop failure rolls the whole op
    back), so per-item seq does not weaken the all-or-nothing guarantee.
  - Broadcast `delete` per attachment, outside the txn.

Idempotency: empty match set returns `{:ok, 0}`, mirroring `Notes.rename_folder`
/ `delete_folder`.

### Transaction boundary — separate seq + txn per table (not unified)

Notes cascade keeps its own seq + transaction; attachments cascade runs in its
own seq + transaction immediately after. **Not merged into one transaction.**

Rationale: the #614 invariant (a cursor pull must never see a renamed row at
seq S, advance past S, and miss its same-seq tombstone) is a **within-table**
guarantee — it holds as long as each table's renamed rows and tombstones share
one seq committed in one txn. That is preserved here. Cross-table, a client may
observe a partial state (notes moved, attachments a beat behind) on the next
poll — ordinary eventual consistency that sync already tolerates everywhere.
Unifying the two would force one context to reach into the other's crypto
internals (`Notes` and `Attachments` are deliberately separate contexts) for
negligible benefit.

### Orchestration — new `Engram.Folders` coordinator

`Engram.Attachments` already depends on `Engram.Notes` (aliases
`Notes.PathSanitizer`). Putting the "do both" logic in `Notes` would invert /
tangle that dependency, and `Notes` should not know attachments exist. So the
"a folder op spans notes + attachments" knowledge gets exactly one home:

```elixir
defmodule Engram.Folders do
  @moduledoc "Coordinates folder-level operations that span notes + attachments."

  def rename(user, vault, old, new) do
    with {:ok, notes} <- Notes.rename_folder(user, vault, old, new),
         {:ok, atts}  <- Attachments.rename_folder(user, vault, old, new) do
      {:ok, %{notes: notes, attachments: atts}}
    end
  end

  def delete(user, vault, folder) do
    with {:ok, %{deleted: notes}} <- Notes.delete_folder(user, vault, folder),
         {:ok, atts}             <- Attachments.delete_folder(user, vault, folder) do
      {:ok, %{notes: notes, attachments: atts}}
    end
  end
end
```

`Notes.rename_folder` / `delete_folder` and `Attachments.*` stay single-table.
The two surfaces repoint to the coordinator:

- **REST:** `FoldersController.rename/2` and the folder-delete action call
  `Engram.Folders.rename` / `.delete`. Response JSON gains an `attachments`
  count alongside the existing notes count (additive; existing field kept).
- **MCP:** `Handlers.handle("rename_folder", ...)` calls `Engram.Folders.rename`;
  result string reports both counts, e.g.
  `"Folder renamed: Docs -> Archive (12 notes, 3 attachments updated)"`.
  (Folder delete is not currently an MCP tool — out of scope here.)

Any future folder-op surface calls `Engram.Folders` and structurally cannot
forget attachments — this is the DRY property that makes the class of bug we are
fixing non-recurring.

### Error semantics

- `rename`: if `Attachments.rename_folder` returns `{:error, :conflict}` (a
  computed target attachment path is occupied) AFTER notes already committed,
  the coordinator returns `{:error, :conflict}` but the note rows have moved.
  This is a pre-existing risk shape (notes rename can itself partially fail vs
  attachments) and acceptable for v1: conflicts on folder rename are rare and
  user-recoverable (rename back / resolve). Documented, not engineered around.
  Note: `Notes.rename_folder`'s own conflict pre-check runs first, so the common
  conflict is caught before either table mutates.
- `delete`: delete is unconditional (no conflict path); both legs are `{:ok, _}`.

### Item 3 — MCP `move_attachment` tool (separate step, lands after the cascade)

- `tools.ex`: `move_attachment_def/0` — name `move_attachment`, input
  `old_path` + `new_path` (both required), description noting it moves the file
  and syncs to devices. Register in `Engram.MCP.Tools.list/0`.
- `handlers.ex`: `handle("move_attachment", user, vault, args)` calls
  `Attachments.move_attachment/4`, maps `{:ok, _}` / `{:error, :not_found}` /
  `{:error, :conflict}` to user-facing strings (same shape as `rename_note`).

## Testing (TDD — failing test first per function)

`Engram.Attachments` tests (ExUnit, real Postgres sandbox):
- rename: attachment under `Docs/` moves to `Archive/`; old path gets a
  soft-deleted tombstone at the shared seq; `storage_key` unchanged.
- rename: nested `Docs/sub/a.png` → `Archive/sub/a.png`.
- rename: folder with no attachments → `{:ok, 0}`, no writes.
- rename: target attachment path already occupied → `{:error, :conflict}`,
  no mutation.
- delete: attachment under folder gets `deleted_at` + new seq; no tombstone row.
- delete: empty → `{:ok, 0}`.

`Engram.Folders` tests:
- rename moves BOTH a note and an attachment under the same folder in one call.
- delete soft-deletes BOTH.

Surface tests (the drift guard): one test through the MCP handler (or REST
controller) asserting a folder rename moved an attachment end-to-end — proves
the coordinator is actually wired at the surface, not just unit-correct.

MCP tool test: `move_attachment` tool moves an attachment via the handler.

## Files touched

- `lib/engram/attachments.ex` — add `rename_folder/4`, `delete_folder/3`
  (+ small private prefix-scan helper).
- `lib/engram/folders.ex` — **new** coordinator module.
- `lib/engram_web/controllers/folders_controller.ex` — repoint rename + delete.
- `lib/engram/mcp/handlers.ex` — repoint `rename_folder`; add `move_attachment`.
- `lib/engram/mcp/tools.ex` — add `move_attachment` tool def + register.
- tests under `test/engram/attachments_test.exs`, new
  `test/engram/folders_test.exs`, MCP handler test.

## Rollout

Single PR (per workspace convention: one PR for the whole change). One mix.exs
version bump. No migration — purely behavioral over existing schema. Self-host
and SaaS both benefit; no config flag.
