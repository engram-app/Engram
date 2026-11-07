defmodule Engram.Repo.Migrations.IndexNotesFolderRefNewestExpand do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  `notes_folder_ref_newest`: a folder's live notes, newest first (note ids
  are UUIDv7, so `id DESC` is creation order). The name-terms search leg
  (`Engram.Search.NameTerms.under_folders/2`) reads at most 50 per folder
  for at most 200 folders, so its cost never grows with the notes in a
  folder.

  Not on `updated_at` (rule 2 of `docs/context/maintenance-job-db-load.md`):
  every key column here changes only on create, move or delete, never on a
  content save, so no save that was heap-only stops being so and saves add
  no entry.

  Additive: the previous release ignores it. Dropped by name first, so a
  retry after a failed CONCURRENTLY build rebuilds an INVALID index.
  """

  def up do
    execute "DROP INDEX CONCURRENTLY IF EXISTS notes_folder_ref_newest"

    execute """
    CREATE INDEX CONCURRENTLY notes_folder_ref_newest
    ON notes (vault_id, folder_ref_id, id DESC)
    WHERE deleted_at IS NULL AND kind = 'note'
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS notes_folder_ref_newest"
  end
end
