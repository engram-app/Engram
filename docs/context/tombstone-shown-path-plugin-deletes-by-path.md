# Tombstones must carry the SHOWN path: the plugin deletes by path

_Last verified: 2026-11-16 (S5 readers #2610 @ c7441cf05, writer #2609, plugin origin/main @ 5d4917c4)_

## Trigger

You are writing a tombstone, a delete broadcast or a rename old path, or reading
a note's stored `path_*` once folders move without cascading (S5).

## Why it matters: the plugin never checks the id

On catch-up the Obsidian plugin applies a delete by PATH. In
`applyChange` (`src/sync.ts:11219`, engram-obsidian-sync) the delete branch
looks up `noteIdMap.get(normalized)` and `vault.getFileByPath(normalized)`
(`:11233`) and trashes that file. It never compares the tombstone's `note_id`
with the local note's id. The id is only passed to `forgetRemoteDelete`
(`:11325`), after the file is already trashed.

So a tombstone with a stale path deletes whatever unrelated local note now sits
at that path.

## Root cause: stored paths go stale under S5

The S5 writer (#2609) renames ONE folder row (`notes_cascaded = false`) and
leaves every note under it at its old stored `path_*`. Folder A moves to B, note
`A/x` is now shown at `B/x`, but its row still says `A/x`. And `A/x` is free for
a NEW note to take (`Notes.free_stale_slot`).

## Rule

Every tombstone, delete broadcast and rename old path uses the SHOWN path:
folder chain plus name. Get it from the one shared helper, never from
`decrypt_or_raise!` or a stored column:

- `Engram.Notes.Location.shown_path/3`, `lib/engram/notes/location.ex:430`
  (on #2610). Batch form: `Location.put_paths/3` (`:443`).
- One rule: a row is shown at chain plus name only when its OWN chain holds a
  folder moved without a cascade. Any other row, drift included, is at its
  stored path.
- Occupancy checks (resurrect, restore, claim) use shown paths too:
  `Location.named_ids_at/3` (`:192`).

## Bug class this prevents

- **Deleting an unrelated note.** A rename or delete of `B/x` tombstones `A/x`,
  and every catch-up plugin trashes the new note at `A/x`.
- **Ghost notes in the web app.** `B/x` never gets a delete, so web clients keep
  a ghost at `B/x`.
- **Duplicate live notes on restore.** A restore or CRDT re-create checked only
  the stored-key unique index, so it missed a note shown at `B/x` by name and
  landed a second live note there.

## Expand/contract lesson

S5 was first one PR. Review found a BLOCKER: the release that first WRITES
`notes_cascaded = false` was also the first that READS it right, so the rollback
target and old nodes in a rolling deploy misread moved rows (overwrite the note
at the new path, resurrect notes at old paths, write old paths into links).
Fix: split it.

1. **#2610, readers, inert.** Nothing writes a moved folder; every new branch
   runs only in a vault holding one. Exposes `Location.s5_reads/0`.
2. **#2609, writer, fleet-gated.** Moves without cascading only when every node
   reports `s5_reads` (`Cluster.Readiness`) and the rollback floor is at or
   above the #2610 release.

Same rule as `migrate-data-rollback-trap.md`: never switch reads and change
writes in one release.

## How to test it

- **Moved-folder fixtures.** Build rows in the writer's shape with
  `FolderRows.move_uncascaded!/3` (`test/support/folder_rows.ex`), never with
  the release's own code. `test/engram/folders/moved_reads_test.exs` asserts
  saves, renames and relocates at the old path touch a DIFFERENT note, and that
  single, batch and folder deletes tombstone at the shown path.
- **Statement budgets.** `test/engram/folders/moved_reads_budget_test.exs` pins
  zero-moved-vault costs (re-create 3, relocate 38, resurrect 25, three-note
  undo 53) at #2606's counts. The moved-vault bit must ride an existing read.
