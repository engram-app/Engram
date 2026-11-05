defmodule Engram.Repo.Migrations.IndexNotesFolderLiveExpand do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  `notes_folder_live`: a folder-subtree filter (`Engram.Search.NoteFilter`,
  `folder_id = ANY(...)`) and its complement (`NOT ...`, the `:exclude`
  path) as index-only scans over a vault's live notes. INCLUDE `(id,
  user_id)` (`user_id` because the RLS policy reads it).

  `notes_folder (vault_id, folder_id)` already serves the lookup, but it is
  not partial and not covering: staging EXPLAIN 2026-11-05 (1,518-note
  vault) read one heap block per matching note (810 matches, 733 blocks),
  and the complement cannot use it at all, so it read the heap of every live
  note (7 to 13 ms per 1k). Kept: the folder-marker lookup needs it.

  Write cost: one more entry on a non-HOT note write; `notes_recent_index`
  already makes every content write non-HOT.

  Additive: the previous release ignores it. Dropped by name first, so a
  retry after a failed CONCURRENTLY build rebuilds an INVALID index.
  """

  def up do
    execute "DROP INDEX CONCURRENTLY IF EXISTS notes_folder_live"

    execute """
    CREATE INDEX CONCURRENTLY notes_folder_live ON notes (vault_id, folder_id)
    INCLUDE (id, user_id) WHERE deleted_at IS NULL AND kind = 'note'
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS notes_folder_live"
  end
end
