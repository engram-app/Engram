# Context Doc: Safer delete — op ids, restore, trash retention

_Last verified: 2026-10-25 (safer delete phase 1, epic #609)_

## Status
Phase 1 shipped behind MCP only. REST and the web app still delete without an
op id (their rows are restorable by nobody until they pass one).

## What This Is

Every MCP delete (`delete_note`, `delete_folder`, `delete_attachment`) is a soft
delete stamped with one **op id**. The tool returns `delete_op_id` and
`restorable_until`; `restore_deleted(op_id)` brings back everything that call
removed. Background: on 2026-10-24 an agent's `delete_folder` removed 7,440
attachments and only S3 versioning saved the blobs (#2159).

## How it works

- **Stamp.** `notes.delete_op_id` / `attachments.delete_op_id` (nullable uuid,
  partial index `WHERE delete_op_id IS NOT NULL`). The existing delete paths take
  `op_id:` (`Notes.delete_note/4`, `Notes.delete_scanned/4`,
  `Attachments.delete_attachment/4`, `batch_delete/4`, `delete_scanned_paths/4`,
  `Folders.delete/4`, `Folders.batch_delete/4`). There is no second delete path.
- **Only tombstones carry a stamp.** Every undelete clears it: `move_note`'s
  resurrect, the folder-marker revive in `upsert_folder_marker(s)`, and
  `Attachments.revive_tombstones/3`. Only live rows can be deleted, so a
  tombstone's stamp is always its own delete's. A retried folder delete stamps
  only what IT removed; earlier rows keep the earlier op.
- **Rename/move tombstones are never stamped**, so an op can never resurrect a
  rename's old path.
- **One restore entry point: `Folders.restore_op/3`.** It plans both tables
  first (read-only), refuses with `{:error, {:limit_reached, key, limit,
  current}}` before writing anything if the result would pass `notes_cap` or
  `attachment_bytes_cap`, then restores markers (through the create path, which
  revives in place), notes, attachments. Skips, with a reason: `:path_taken`
  (a live row holds the path), `:expired` (past retention), `:unavailable` (blob
  claimed or reaped by the GC), `:changed` (row moved since the plan).
- **Notes** come back through `move_note/7`, the same resurrect leg an id-keyed
  re-push uses, minus the delete-wins window (`recent_same_path_tombstone?`).
  Paths are claimed in the index authority BEFORE the row transactions
  (`crdt-create-is-a-rename.md`), then chunks of 100 per transaction. Each note
  gets a fresh seq, an upsert broadcast and `ContentCommit.enqueue_jobs` (the
  delete dropped its Qdrant points, so **a restore re-embeds: real Voyage spend**
  for a large undo).
- **Attachments** come back only through `Attachments.revive_tombstones/3`.

## Retention

`trash_retention_days` in `LimitKeys`: 7 Free, 30 Starter/Pro (pending product
confirmation). Read ONLY through `Billing.trash_retention_days/1`. Every "no cap"
spelling (nil, -1, self-host `:unlimited`) takes the Pro window: for retention,
"unlimited" cannot mean "keep forever" or the GC never reaps. Floors at 1 day.
`AttachmentBlobGC` cuts off per vault owner with that same function, and
`restore_op` filters expired rows with it, so the two windows cannot disagree.
Notes have no sweep in phase 1: an expired note tombstone just stops being
restorable.

## Traps

1. **The GC race (#2195).** A row revived after the GC claimed its key but before
   the S3 delete came back live with no bytes. `revive_tombstones/3` takes the
   vault lock FIRST (`next_seq_block!`, the lock the GC claim takes) and revives
   only rows with a `storage_key`, no claim younger than
   `AttachmentBlobGC.stale_claim_minutes/0`, and no live row at the path. Never
   write `deleted_at: nil` on an attachment anywhere else.
2. **A unique violation inside a restore chunk aborts the chunk's transaction.**
   The plan pre-checks taken paths, so it needs a concurrent create in the gap.
   The call then raises; a retry is safe (committed chunks left the op).
3. **The delete's `ReleaseIndexEntries` job can run after a fast restore's
   claim** and drop it. The restored note is then unclaimed, which projection
   treats as benign (it never acts on absence).
4. **`restore_op` re-uses `create_folder_markers`**, which may revive a newer
   marker tombstone than the op's own; the op's marker then stays a tombstone
   with its stamp. Harmless (a live marker exists), but a repeat restore lists
   it again as a no-op create.
5. **Restore is not exempt from `notes_cap`**, unlike a sync resurrect
   (`genesis_resurrect`): an undo can bring back thousands of notes at once.

## Tests

- `test/engram/attachments/revive_tombstones_test.exs` — the race itself (revive
  from inside the GC's S3 delete stub).
- `test/engram/delete_op_id_test.exs` — stamping, retried delete, rename tombstones.
- `test/engram/folders_restore_op_test.exs` — 1,000+ item chunked restore, path
  taken, caps, expiry, cross-tenant RLS with a CONTROL test.
- `test/engram/workers/attachment_blob_gc_test.exs` — retention per user and self-host.
- `test/engram/mcp/handlers_restore_deleted_test.exs` — the MCP contract.
