# Attachment Actions + Durable Rename Convergence + Real-Time Sockets

**Date:** 2026-06-16
**Status:** Design — approved for planning
**Repos:** `engram` (backend + `frontend/`) and `engram-obsidian-sync` (plugin)
**Branches:** `feat/attachment-actions-and-rename-convergence` (engram) + a paired
plugin branch of the same name (for `plugin_branch` e2e pairing)
**Supersedes/extends:** Phase 1 — `2026-06-14-attachments-in-file-tree-design.md`

## Problem

Phase 1 made attachments **display + preview only** in the web file tree —
they render and open read-only, but every action affordance (context menu,
long-press, drag) was deliberately suppressed on attachment rows. Phase 2 turns
those on: **delete, rename, move**, with full multi-select batch parity
alongside notes.

Designing the move/rename exposed two deeper issues that this spec also closes:

1. **The S3 object key is path-derived** (`Storage.key/3` =
   `"<user>/<vault>/<path>"`), so a naive move would require physically
   relocating the blob and could let a reused path clobber another file's blob.
2. **Attachment sync is poll-only and lossy on renames.** The plugin converges
   via `GET /attachments/changes` (apply `deleted:true` → trash; else upsert at
   path). A move that simply repoints a row emits only `{newPath}` — never
   `{oldPath, deleted:true}` — so the plugin would keep a **duplicate** at the
   old path, and its full-reconcile would *re-push* (resurrect) the orphan.
   Notes/folders have the **same latent rename gap**, masked only by their
   real-time socket broadcast (which an offline client misses).

This spec ships actionable attachments **and** the durable-tombstone primitive
that makes a rename converge on every path (socket, poll, and offline
reconcile), then extends that primitive to notes and folders.

## Scope

**In:**
- Attachment **delete / rename / move**, single + batch (mixed note+attachment
  multi-select), reusing the existing tree-action dialogs.
- **S3 re-keying:** new attachment blobs keyed by row UUID, decoupled from the
  vault path. Move/rename becomes pure metadata (zero blob I/O).
- **Durable old-path tombstone** on attachment move (poll/offline convergence).
- **Real-time `attachment_changed` socket broadcast** + plugin channel handler
  (note-parity).
- **Extend the rename tombstone to notes + folders** (`rename_note`,
  `rename_folder`, incl. the folder cascade fan-out).

**Out / deferred:**
- **Upload on web** (drag-drop + paid gating) — Phase 3.
- **Legacy blob re-key backfill** — existing path-keyed blobs keep working via
  the `storage_key` column; a backfill is optional (per "data wipeable
  pre-launch") and not load-bearing.
- **Tombstone pruning / GC** — tombstones accumulate (one per move; N+1 per
  folder rename). Bounded, harmless (partial index excludes them). A prune job
  is a tracked follow-up.
- **Full version-vector reconcile** ("month-stale vault converges perfectly")
  — belongs to the existing Sync Architecture Overhaul track. This spec adds
  the correct *primitive* (durable rename tombstone) but not the three-way
  baseline-diff reconcile.
- **Offline-local-delete detection audit** (file deleted while app closed) —
  tracked follow-up feeding the sync-overhaul track.

## Decisions (locked during brainstorming)

1. **Batch parity** — attachments join multi-select batch delete/move (mixed
   note+attachment selections); rename stays single-item (notes have no batch
   rename either).
2. **UUID-keyed S3 storage** — `storage_key` decoupled from the vault path;
   move/rename never touches the blob. S3 layout no longer mirrors the vault.
3. **Durable old-path tombstone** on every move/rename (the convergence signal).
4. **Real-time sockets** — add `attachment_changed` broadcast + plugin handler,
   bringing attachments to note-parity.
5. **One unified spec, two sequenced PRs** — PR1 (low-risk corner: attachments
   + sockets + frontend + plugin), PR2 (high-blast-radius: notes/folders
   tombstones). Plus the paired plugin PR.
6. **Notes/folders rename tombstone folded in** (PR2) — same primitive, applied
   to the busiest path in the product.

## Architecture

### A. S3 storage re-keying (foundational, PR1)

Decouple the object key from the mutable vault path; key by the immutable row
UUID instead.

- New builder `Storage.object_key(user_id, vault_id, uuid)` →
  `"<user>/<vault>/objects/<uuid>"`. The `objects/` namespace keeps new keys
  visually distinct from legacy path-derived keys in the bucket.
- `Attachments.prepare_upload/8` mints `storage_key` from the row UUID
  (`att_id`), **not** `Storage.key(path)`.
- `Attachments.delete_external/_` deletes `att.storage_key` (the column) — not a
  path-recompute. Correct for both new UUID-keyed and legacy path-keyed rows.
  **This is the current latent bug** (delete recomputes from `path`; reads
  already prefer `storage_key`).
- Reads (`get_attachment/3`, `UserDekRotation`) already route through
  `storage_key` → unchanged.
- **Legacy blobs keep working** via their stored path-key. No backfill required.

**Why this matters:** with path-keyed storage, a move would have to physically
relocate the blob, and a new upload to a vacated path would compute the same
key and **clobber** the moved blob (S3 last-write-wins; Database adapter
`ON CONFLICT (storage_key)`). UUID-keying makes a new upload always compute a
fresh key — collision impossible — and makes move a pure metadata edit.

### B. Attachment move/rename + tombstone + batch (PR1)

**`Attachments.move_attachment(user, vault, old_path, new_path)`** — mirrors
`Notes.rename_note/4`. In one `Repo.transaction` under the existing per-path
advisory lock:

1. **No-op guard:** `old == new` → idempotent `{:ok, att}` (no tombstone).
2. **Conflict check:** target `path_hmac` exists among non-deleted rows →
   `{:error, :conflict}` (→ 409).
3. **Repoint the live row** (id stable): re-encrypt `path` (same DEK, AAD bound
   to the **unchanged** row id), recompute `path_hmac`, bump `updated_at`.
   `storage_key`, `content_*`, and the blob are untouched.
4. **Insert the tombstone** at `old_path`: fresh UUID, `path` encrypted under
   its own id-AAD, `path_hmac = hmac(old_path)`, `deleted_at = updated_at = now`,
   `storage_key = nil`, `content_hash` = carried from the live row (satisfies
   the changeset; value irrelevant — row is deleted). Sole purpose: surface
   `{old_path, deleted:true}` in the feed.

The UUID stays stable, so the web's `/note/:id` routing and the open preview tab
survive the move for free.

**Endpoints** (mirror the notes shapes):
- `POST /attachments/rename` `{old_path, new_path}` — rename **and** single
  move (any path change). Gated by `Billing.check_feature(:attachments_enabled)`.
- `POST /attachments/batch-move` and `POST /attachments/batch-delete` under the
  existing `EngramWeb.Plugs.IdempotencyKey` pipeline (require
  `X-Idempotency-Key`), mirroring `/notes/batch-*`.

**Mixed selections:** the frontend partitions a selection by kind and calls the
notes and attachments batch endpoints separately; each is independently
idempotent.

### C. Attachment socket broadcast + plugin handler (PR1 + plugin PR)

- The attachment context emits a new **`attachment_changed`** event on the
  existing `sync:<user>:<vault>` topic (mirroring `note_changed`), via
  `EngramWeb.Endpoint.broadcast` (or `broadcast_from/4` to exclude the pusher).
- Payload: `{op: "upsert" | "delete", path, mime_type, size_bytes, mtime}`.
- A **move broadcasts two events** — `delete(old)` + `upsert(new)` — exactly
  like `rename_note`. Delete and batch ops broadcast correspondingly.
- **Plugin:** subscribe to `attachment_changed` on the existing sync channel;
  apply with the **same logic as the poll path** (`deleted` → `trashFile` +
  `removeEmptyFolders`; else fetch blob + write), recording the `syncState`
  hash to **echo-suppress** the resulting local modify event. The plugin keeps
  pushing attachments over HTTP — this is receive-only parity, no client→server
  socket change.

### D. Frontend tree actions (PR1)

- `viewer/tree/tree-row.tsx` — **un-suppress** context-menu / long-press / drag
  on the `attachment` branch.
- `viewer/folder-tree.tsx` — extend `onMove`, `onRenameCommit`,
  `openDelete`/`commitDelete`, `partition`, `rowsFor`, `kindOf`,
  `titleForItem` to the `attachment` kind, **threading the path** (not id) per
  the Phase-1 `parseItemId` shape (`{kind:'attachment', path}`).
- `api/queries.ts` — add `useRenameAttachment`, `useBatchMoveAttachments`,
  `useBatchDeleteAttachments` with cache invalidation, mirroring the notes
  hooks. Reuse the `tree-actions/` dialogs unchanged.
- **Move into a synthetic (attachment-only) folder** "just works" — it is a
  path-string prefix change; no backend folder needs to exist.

### E. Notes + folders rename tombstone (PR2, high blast radius)

Extend the same primitive to `Notes.rename_note/4` and `Notes.rename_folder/4`,
closing the offline-rename resurrection gap (currently masked by the socket).

- **`rename_note`** — after the in-place repoint, insert **one** tombstone at
  the old path (deleted note row, fresh UUID, path encrypted under its id-AAD,
  `deleted_at = now`).
- **`rename_folder`** — cascades via `update_all` over every contained note
  (`A/x.md → B/x.md`). The poll/offline reconcile is path-based, so each vacated
  path needs a durable delete signal: emit **N+1 tombstones** (one per contained
  note + the folder marker), batched via `insert_all`.

**Interactions to handle (and assert in tests):**
- **Embeddings:** `rename_note` enqueues `EmbedNote`; tombstone rows must **not**
  enqueue (they are deleted).
- **Version vectors:** tombstones are `deleted` and must stay out of the
  version-conflict path; a later re-create at the old path inserts a fresh live
  row (partial unique index `WHERE deleted_at IS NULL` permits it).
- **Folder counts / markers:** count queries already filter `deleted_at IS
  NULL`, so tombstones are invisible — assert this holds.
- **Transaction size:** folder-rename tombstones are written in the same txn as
  the cascade; use a batched `insert_all`.

## Data flow — attachment move (the crux)

```
Web: right-click attachment → Move dialog → useRenameAttachment
        │  POST /attachments/rename {old, new}
        ▼
move_attachment (one txn, advisory lock):
  • conflict-check hmac(new) among non-deleted → 409 if taken
  • live row: path→new, re-encrypt path (AAD=id unchanged), hmac(new), updated_at
              (storage_key + blob UNTOUCHED — uuid-keyed)
  • tombstone row @ old: new uuid, hmac(old), deleted_at=now, storage_key=nil
        │
        ├─▶ socket: attachment_changed {delete, old} + {upsert, new}  ── live plugins
        │            (plugin: trash old + write new, echo-suppressed)
        │
        └─▶ GET /attachments/changes?since  (poll / offline reconnect)
                 → {old, deleted:true}  (tombstone)  → plugin trashes old
                 → {new}                (live row)   → plugin writes new
        ▼
   Web tree + preview: UUID stable → open tab unaffected; tree re-keys to new path
```

## Error handling / edge cases

- **Conflict** (move onto an occupied path) → `{:error, :conflict}` → 409,
  surfaced in the move/rename dialog.
- **Cross-kind path collision** (note vs attachment at the same path) — an
  existing non-issue (Obsidian forbids it); out of scope. Conflict checks stay
  within-kind, matching `rename_note`.
- **No-op move** (`old == new`) — idempotent, no tombstone.
- **Tombstone accumulation** — one per move, N+1 per folder rename; partial
  unique index excludes them so they never block re-creation. Pruning deferred.
- **Storage failures** on delete remain best-effort + logged (row already
  soft-deleted), unchanged from today.

## Testing strategy (TDD per unit)

**Backend (`mix test`):**
- `move_attachment/4`: repoint correctness (path re-encrypt under stable AAD),
  tombstone emitted at old path, conflict → `:conflict`, no-op idempotency,
  tenant isolation, `storage_key`/blob untouched.
- `delete_external` deletes by `storage_key` (new UUID-keyed **and** legacy
  path-keyed rows).
- `prepare_upload` mints UUID-derived `storage_key`; a new upload to a vacated
  path does **not** clobber a moved blob.
- `POST /attachments/rename` + `batch-move` + `batch-delete`: shape, auth
  (401), paid gating, idempotency replay, conflict (409).
- `attachment_changed` broadcast: delete(old)+upsert(new) on move; payload shape.
- **PR2:** `rename_note` tombstone; `rename_folder` N+1 tombstone fan-out;
  no `EmbedNote` enqueue for tombstones; folder counts ignore tombstones;
  re-create at a vacated path succeeds.

**Frontend (`bun test`):** tree-action wiring for the attachment kind (menu /
long-press / drag un-suppressed), the three mutations + cache invalidation,
mixed-selection partition. Run `lint:obsidian` / `lint:css` / biome locally
before pushing.

**Plugin (`bun test`):** `attachment_changed` apply (trash / write) +
echo-suppression via `syncState`.

**E2E (`make e2e`, paired plugin branch):** web-originated attachment move
converges in Obsidian — **no duplicate, no resurrection** — over both the live
socket and a poll/offline-reconnect catch-up. Same for a note rename and a
folder rename (PR2).

## PR structure

- **PR 1** — engram (backend + frontend) + **paired plugin PR**: A + B + C + D.
  Proves the tombstone primitive in the low-risk attachment corner; ships
  real-time parity.
- **PR 2** — engram: E (notes + folders rename tombstones + offline-reconcile
  tests). The core-sync change, isolated for focused review.

One `mix.exs` version bump per engram PR; one plugin `manifest.json` bump per
plugin PR (bump once at open, per project rules). Conventional commits.

## Follow-up issues (filed, not built here)

1. **Tombstone pruning / GC** — bound unbounded tombstone growth (retention >
   max supported offline window).
2. **Reconcile divergence audit** — offline-local-delete detection
   (`syncState ∖ localFiles`) + tombstone-retention-vs-max-offline; feeds the
   Sync Architecture Overhaul (version vectors + three-way baseline reconcile).
3. **Legacy attachment blob re-key backfill** — optional migration of
   path-keyed blobs to UUID keys (cosmetic; reads already route via
   `storage_key`).
