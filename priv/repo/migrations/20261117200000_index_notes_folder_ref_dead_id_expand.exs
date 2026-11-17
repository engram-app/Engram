# Shared helpers; see each file for why they are not in lib/.
Code.require_file("bounded_index_build.exs", __DIR__)
Code.require_file("migration_log.exs", __DIR__)

defmodule Engram.Repo.Migrations.IndexNotesFolderRefDeadIdExpand do
  use Ecto.Migration

  alias Engram.Repo.Migrations.{BoundedIndexBuild, MigrationLog}

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  `notes_folder_ref_dead_id`: a folder's dead notes in id order, the twin
  of `notes_folder_ref_live_id` (20261111020300) for tombstones. The
  moved-folder feed (`Engram.Notes.list_moved_changes/4`, O(1) folder
  rename plan S5, Engram#2523) serves a note that died under a folder after
  that folder moved without a cascade as an id-keyed upsert at the
  folder's seq, so a plugin older than S4 moves the file before the
  tombstone trashes it, as the cascade's old-path tombstone did. It reads
  at most a page of ids per subfolder in id order, a lazy Merge Append.
  INCLUDE (user_id, seq): the RLS policy reads `user_id` and the leg filters
  `seq > folder seq`, so a tombstone that predates the move is rejected from
  the index, with no heap fetch (trash is never purged, so a subfolder may
  hold many).

  `folders_moved_seq`: the folders moved without a cascade, by seq, dead
  ones included (a folder deleted after its move keeps its seq, and its
  notes still need relocating): the leg range-seeks `seq > cursor`, so a
  page reads only the moved folders past the client's cursor. The subtree
  walk over dead subfolders uses `folders_parent` `(vault_id, parent_id)`,
  which has no `deleted_at` predicate.

  No key or included column changes on a content save (a tombstone is not
  saved), so no save stops being heap-only. One entry per note delete.

  Additive: the previous release ignores it. Prod size not measured here:
  one entry per tombstone (sql-lane reads the count before release). The
  CONCURRENTLY build runs inside BoundedIndexBuild's 110 s budget, under
  SHARE UPDATE EXCLUSIVE (reads and writes go on); a build that outruns
  it is cancelled and left INVALID, the boot raises, and the next boot
  drops and rebuilds it. Rerun-safe with no operator step.
  """

  def up do
    started = MigrationLog.now()

    BoundedIndexBuild.build!(
      repo(),
      [
        {"notes_folder_ref_dead_id",
         "ON notes (vault_id, folder_ref_id, id) INCLUDE (user_id, seq) " <>
           "WHERE deleted_at IS NOT NULL AND kind = 'note'"},
        {"folders_moved_seq",
         "ON folders (vault_id, seq) INCLUDE (user_id) WHERE NOT notes_cascaded"}
      ],
      lock_key: 20_261_117_200_000,
      label: "index_notes_folder_ref_dead_id"
    )

    MigrationLog.indexes(
      repo(),
      "index_notes_folder_ref_dead_id",
      ~w(notes_folder_ref_dead_id folders_moved_seq),
      started
    )
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS folders_moved_seq"
    execute "DROP INDEX CONCURRENTLY IF EXISTS notes_folder_ref_dead_id"
  end
end
