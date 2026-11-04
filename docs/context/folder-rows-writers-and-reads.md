# Context Doc: folder rows, who writes them, and when a reader may trust `folder_ref_id`

_Last verified: 2026-11-03 (attachment reference stamp, #2413)_

## What this is

`folders` is a second, derived key for folders: one encrypted segment name per
folder, `parent_id`, `full_path_hmac` (equal to `notes.folder_hmac`). Notes and
attachments point at their folder with `folder_ref_id`. The STORED paths
(`notes.path_*` / `folder_*`, attachment `path_*`, tombstones) are still the
authority and are still written everywhere: the previous release is the
rollback target and ignores the new column. Root has no row, so a root item's
`folder_ref_id` is NULL, the same as "not resolved yet".

## One module owns the table

`Engram.Folders.Rows`: hashes, name encryption, `ensure/4` (find-or-create a
path), `ensure_all/3`, `ensure_markers/3`, `subtree/3`, `subtree_refs/3`,
`ids_at/3`, `rename/4`, `soft_delete/4`, `restore_op/2`, `unmark_explicit/3`.
Everything runs inside the caller's `Repo.with_tenant`. `FolderTable` (the
backfill) shares its primitives and nothing else (it works in memory on the
maintenance pool).

`ensure/4` is `INSERT ... ON CONFLICT DO NOTHING` then a read of the winner: two
creators of one new folder neither crash nor abort the transaction (no 25P02,
no savepoint needed). Call it AFTER the vault seq lock like every other writer.

## Writers (each also writes the stored paths)

| Writer | Where |
|---|---|
| note create (REST, MCP, CRDT genesis) | `Notes.do_bare_insert` |
| note move / CRDT relocate / resurrect / restore | `Notes.move_note` |
| note rename (REST, MCP, ProjectVaultIndex, batch move) | `Notes.do_rename_note_inner` |
| folder rename / move (batch) | `Notes.do_rename_folder`: `Rows.rename` then `Rows.ensure_all` |
| folder marker create / revive | `Notes.upsert_folder_batch`, `do_create_folder_marker`: `Rows.ensure_markers` |
| marker-only delete | `Notes.delete_folder_marker`: `Rows.unmark_explicit` |
| folder delete / restore | `Folders.delete_scanned`, `Folders.do_restore_op` |
| attachment upload (single, chunked) | `Attachments.write_row` (via `commit_row`) |
| attachment move (single, batch, folder cascade) | `Attachments.do_move_attachment`, `apply_moves` |

For notes the `notes_set_folder_ref` trigger turns `folder_hmac` into the
reference; the writer's job is to make sure the row exists first. Attachments
have no trigger: the writer sets `folder_ref_id` AND `folder_ref_stamp` (the
`path_nonce` of the path the folder came from) through
`Rows.attachment_ref/2`. A DEK rotation carries a current stamp to the new
nonce (`Rows.carry_attachment_ref/3`).

A folder rename updates the folder rows IN PLACE (ids survive): the renamed row
takes the new name and parent, its descendants get a new `full_path_hmac`. That
is descendant folders only; notes join by id and need nothing. When a live row
already sits at the target, the source rows are folded into it (`merge_subtree`).

## When may a reader trust a reference?

Attachments: only while its stamp matches (`folder_ref_stamp = path_nonce`,
`Rows.attachment_ref_current/0`), since #2413. Every path write draws a fresh
nonce, so a task on the previous release that writes or moves an attachment
leaves a mismatch; the reader checks those rows against their decrypted path,
and `BookkeepingDrain` re-points and stamps them through the
`attachments_folder_ref_stale` index within 15 minutes. Before the
`FolderTable` v2 pass has stamped a vault, every row mismatches and the scan
is the old whole-vault decrypt. (The ledger's `completed_at` watermark,
`verified_until/0`, and the nightly re-verify it needed are gone.) Whatever
the route, a row is kept only if its decrypted path is in the folder: the
reference only narrows what is read.

Notes need no timestamp: a NULL reference with a non-root `folder_hmac` is
unresolved by construction (the stored hash classifies it), so
`Notes.fetch_decrypted_live_rows` always adds those through the old decrypt.
Markers never carry a reference; one is "resolved" when a live row sits at its
path hash.

## Gotchas

- `Attachments.scan_under/4` is the one attachment scan for folder operations.
  Do not add `list_attachments/2 |> filter by prefix` back.
- `Engram.FolderRows` (test support) seeds and reads folders; to simulate the
  previous release's write use `Engram.Fixtures.insert_note!` (no folder row)
  or, for an attachment, NULL `folder_ref_stamp` (or rewrite `path_nonce`).
- A restore that cannot revive a folder row (a live sibling took the name) leaves
  restored notes pointing at a deleted row. Folder rows are soft-deleted, so
  the `ON DELETE SET NULL` FK never fires for them; the
  `notes_set_folder_ref_on_restore` trigger (20261103140200) re-resolves the
  reference on the restore itself (the live row, or NULL for the drain). The
  canary's `folder_ref` invariant counts any reference to a deleted row that
  is left (no partial index can express "names a deleted row").
- An attachment whose path does not decrypt is stamped `'\x00' || path_nonce`
  (`Rows.unreadable_attachment_stamp/1`) by `FolderTable`: logged once, out of
  the drain's index until a writer gives it a fresh nonce, never trusted.
- Hard-deleting a folder row (only a vault purge does) runs the FK's
  `ON DELETE SET NULL` lookup on `notes` / `attachments`; the vault-leading
  indexes serve it and the purge deletes those rows first, so no extra index.
