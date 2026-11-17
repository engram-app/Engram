defmodule Engram.Repo.Migrations.DropFoldersParentOnlyKeys do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  Drops `folders_parent (vault_id, parent_id)` and `folders_parent_all_ids
  (vault_id, parent_id, id) INCLUDE (user_id)`, replaced by the previous
  migration's `folders_parent_name_ids`, which carries `name_hmac` after
  `parent_id` (`IndexFoldersParentNameKeys`: a live folder walk that picks
  it still keys the name). Its `(vault_id, parent_id)` prefix serves the
  parent FK's check and the dead-row subtree walk, so nothing loses an
  index. CONCURRENTLY, rerun-safe; no code names
  the dropped indexes.
  """

  def up do
    execute "DROP INDEX CONCURRENTLY IF EXISTS folders_parent"
    execute "DROP INDEX CONCURRENTLY IF EXISTS folders_parent_all_ids"
  end

  def down do
    execute "CREATE INDEX CONCURRENTLY IF NOT EXISTS folders_parent ON folders (vault_id, parent_id)"

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS folders_parent_all_ids
    ON folders (vault_id, parent_id, id) INCLUDE (user_id)
    """
  end
end
