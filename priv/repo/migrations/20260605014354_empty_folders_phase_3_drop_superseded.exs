defmodule Engram.Repo.Migrations.EmptyFoldersPhase3DropSuperseded do
  use Ecto.Migration

  # Phase 3: drop the old path unique index after phase 1's
  # `notes_user_vault_path_v2` has served all writers for at least
  # one deploy cycle. Concurrent drop does not block reads/writes.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "DROP INDEX CONCURRENTLY IF EXISTS notes_user_id_vault_id_path_hmac_index"
  end

  def down do
    execute """
    CREATE UNIQUE INDEX CONCURRENTLY notes_user_id_vault_id_path_hmac_index
      ON notes (user_id, vault_id, path_hmac)
      WHERE deleted_at IS NULL
    """
  end
end
