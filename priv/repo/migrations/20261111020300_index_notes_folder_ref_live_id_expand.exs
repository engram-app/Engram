# Shared summary line; see the file for why it is not in lib/.
Code.require_file("migration_log.exs", __DIR__)

defmodule Engram.Repo.Migrations.IndexNotesFolderRefLiveIdExpand do
  use Ecto.Migration

  alias Engram.Repo.Migrations.MigrationLog

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  `notes_folder_ref_live_id`: a folder's live notes in id order (note ids
  are UUIDv7, so a backward scan is newest first). The name-terms search
  leg (`Engram.Search.NameTerms.under_folders/2`) reads at most 50 per
  folder for at most 200 folders, so its cost never grows with the notes in
  a folder. Shared with S2 (one definition, here). INCLUDE (user_id): the
  RLS policy reads it, so an index-only scan answers the tenant check with
  no heap fetch.

  A superset of `notes_folder_ref_live` (20261106100000: `(vault_id,
  folder_ref_id) INCLUDE (id, user_id)`, the same predicate): same leading
  keys, `id` moved from INCLUDE into the key, so every scan that index
  serves this one serves too, plus id order. That one is now redundant; it
  is dropped in a contract step (S6), not here, as the previous release may
  still plan on it.

  Not on `updated_at` (rule 2 of `docs/context/maintenance-job-db-load.md`):
  every key column changes only on create, move or delete, never on a
  content save, so no save that was heap-only stops being so and saves add
  no entry.

  `folders_live_parent_id`: a folder's live children in id order, so the
  leg's descendant walk takes the newest-created subfolders first, at most
  200 read per parent. `id` and `parent_id` change only on create and move;
  `user_id` is included so the walk is index-only.

  Additive: the previous release ignores them. Dropped by name first, so a
  retry after a failed CONCURRENTLY build rebuilds an INVALID index.
  """

  def up do
    started = MigrationLog.now()

    execute "DROP INDEX CONCURRENTLY IF EXISTS folders_live_parent_id"

    execute """
    CREATE INDEX CONCURRENTLY folders_live_parent_id
    ON folders (vault_id, parent_id, id) INCLUDE (user_id) WHERE deleted_at IS NULL
    """

    execute "DROP INDEX CONCURRENTLY IF EXISTS notes_folder_ref_live_id"

    execute """
    CREATE INDEX CONCURRENTLY notes_folder_ref_live_id
    ON notes (vault_id, folder_ref_id, id) INCLUDE (user_id)
    WHERE deleted_at IS NULL AND kind = 'note'
    """

    # Runs the queued statements, so the line reports the built indexes.
    flush()

    MigrationLog.indexes(
      repo(),
      "index_notes_folder_ref_live_id",
      ~w(folders_live_parent_id notes_folder_ref_live_id),
      started
    )
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS notes_folder_ref_live_id"
    execute "DROP INDEX CONCURRENTLY IF EXISTS folders_live_parent_id"
  end
end
