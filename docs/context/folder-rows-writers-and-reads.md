# Context Doc: folder rows, who writes them, and when a reader may trust `folder_ref_id`

_Last verified: 2026-11-17 (S6 step 1a root row reads)_

## What this is

`folders` is a second, derived key for folders: one encrypted segment name per
folder, `parent_id`, `full_path_hmac` (equal to `notes.folder_hmac`). Notes and
attachments point at their folder with `folder_ref_id`. The STORED paths
(`notes.path_*` / `folder_*`, attachment `path_*`, tombstones) are still the
authority and are still written everywhere: the previous release is the
rollback target and ignores the new column. A root item's `folder_ref_id` is
NULL (the same as "not resolved yet"), or, from S6 step 1b on, the vault's
root row (below).

## The root row (S6 step 1, Engram#2523)

`Rows.root_id(vault_id)` is the vault's own id: the root row has that id,
`parent_id` NULL and the empty name, and no folder hangs under it (top-level
folders keep `parent_id` NULL, so the walk is unchanged). A reference to it is
recognized with no lookup (`folder_ref_id = vault_id`). Step 1a (readers)
ships before 1b (writers + the `RootRefs` ledger), and a rolling deploy or a
rollback runs them side by side, so every reader takes a NULL root reference
and a root-row reference as the same root:

- `Rows.live_rows/2` leaves the root row out, so listings (`Location.place/3`,
  the manifest, the vault tree) never show an empty-named folder and a root
  note's `folder_id` stays nil.
- `Rows.public_ref/2` turns the root row into nil wherever a reference
  reaches the wire (`Location.wire_fields/2`, `Wire.create_reply/3`).
- The root page (`Notes.list_notes_in_folder_page/4` for `""`) reads two
  keyset arms (NULL non-drift, and `= root_id`), each on
  `notes_folder_ref_live_id`, merged in id order: an `OR` would read every
  root note or walk the vault.
- Folder counts name the root row's group `""` (its chain path), summed with
  the NULL group. `list_folders_implied_by_notes/2` and the daily snapshot
  skip the root row.
- `Engram.Folders.RootRowReadTest` pins all of the above.

Writers (1b): every note writer resolves its folder through
`Rows.ensure/4` / `ensure_all/4` with `root: true`, so a root note names the
root row, created on first use by `Rows.ensure_root/2` (one `INSERT .. ON
CONFLICT DO NOTHING`). Attachments still pass no option and keep NULL at the
root until their own step. The `root_refs` ledger
(`Engram.DataMigrations.RootRefs`, kill switch `root_refs`, inert until the rollback floor reaches 1a (`Rows.root_writes?/1`), re-verified
daily by one index probe per vault) creates missing root rows (gated like `FolderTable`) and fills live
root notes left NULL by older writers. Tombstones keep NULL: S6 step 9's
`NOT NULL` must deal with them.

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

## Explicit folders (S6 step 4, Engram#2523)

Listings read an empty folder's existence from `folders.explicit`, not from
the `kind = 'folder'` marker rows: `GET /folders/explicit`, `GET /folders`,
`GET /vault/tree` and the folder counts (MCP `list_folder`) go through
`Notes.raw_explicit_folder_rows/2` (`Rows.explicit_rows/2`, index
`folders_explicit_vault_live`, and `folders_explicit_user_vault (user_id, vault_id) WHERE explicit`, which keeps a partial-index fallback to one vault; the counts' folder-rows leg can still read `folders_user`, a known gap pending a `folders_user` drop). The id a listing hands out is the folder row's;
the id-keyed operations (batch delete/move, notes by folder id) resolve it,
and still resolve a marker's id (a marker made after its folder's row keeps
its own id, and the previous release listed it). The flag is trusted only
once it equals the markers (`Rows.explicit_reads?/0`): `FolderTable` sets it
for every live marker, and `ExplicitFolderReconcile` clears it on every row
no live marker names (a cascade before #2639 deleted markers without clearing
the flag on rows it kept, and listed from the flag those would put deleted
empty folders back on disk). Until both ledgers are done the markers are read.
A path delete (`Notes.delete_folder_marker/3`) with no live marker clears the
flag too.

Phase 2 (`Engram.Folders.MarkerStop`, release E): creates stop inserting
markers and make the row explicit alone (`Rows.make_explicit/3`), stamping
`folders.explicit_seq` with the vault seq they took. On only once listings read
the flag and the rollback floor reaches the phase 1 release (a sentinel until
then). Every flag change bumps the vault seq (caches and etags key on it). A
folder delete keeps a row made explicit after its scan (`explicit_seq` > the
seq it read first), the job a live marker did (#2466 H2). A soft delete keeps
the flag, so an undo brings an empty explicit folder back with no marker, and
`Folders.restore_op/3` broadcasts it. `ExplicitFolderReconcile` never clears a
row with `explicit_seq` set. Phases: D reads (writers still insert markers), E
writers stop inserting markers, F a ledger deletes them. The catch-up feed
never carried markers (#976), and the plugin learns explicit folders only
from `GET /folders/explicit`, whose shape is unchanged: no plugin shim.

## Row names (O(1) folder rename plan, Engram#2523)

S2 (expand) adds each row's own name next to its folder reference, so a later
stage can derive a path from the folder chain plus the name:

- `notes` / `attachments`: `name_ciphertext`, `name_nonce`, `name_hmac`,
  `name_ci_hmac`, `name_stamp` (`Engram.Notes.Name.keys/6`, written by the
  notes path builder and `Engram.Attachments.path_attrs/4`).
- `folders`: `name_ci_hmac`, `name_stamp` (`Engram.Folders.Folder.name_keys/3`),
  plus `seq` and `notes_cascaded`, unwritten until S5.
- A name is current only while `name_stamp` equals
  `Engram.Crypto.NameKeys.stamp/1` of its source nonce (`path_nonce`, or the
  folder's `name_nonce`). The `NoteName` ledger fills and heals the rest.

S2 builds NO index on these columns: the backfill sets them on every row, and
an indexed column turns each of those updates into a non-HOT one that adds an
entry to every index on the table. Each index ships with the stage that first
reads it, built CONCURRENTLY on filled data:

| Index | Shape | Owner |
|---|---|---|
| notes by folder and name | UNIQUE `(vault_id, folder_ref_id, name_ci_hmac)` live notes, after a duplicate check | S3 (by-path read switch) |
| attachments by folder and name | UNIQUE `(vault_id, folder_ref_id, name_ci_hmac)` live attachments, after a duplicate check | S3 |
| attachments by folder in id order | `(vault_id, folder_ref_id, id) INCLUDE (user_id)` live | S5 (old-client feed view) |
| folders by structural seq | `(vault_id, seq) WHERE seq IS NOT NULL` | S5 (first writer of `seq`) |

The notes `(vault_id, folder_ref_id, id)` index is S1's
(`20261111020300`).

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
