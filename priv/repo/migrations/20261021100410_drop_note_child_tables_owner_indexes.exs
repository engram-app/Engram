defmodule Engram.Repo.Migrations.DropNoteChildTablesOwnerIndexes do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # The indexes that backed the owner FKs dropped by 20261021100400. Their
  # own migration so the drop runs CONCURRENTLY (no ACCESS EXCLUSIVE).
  def up do
    drop_if_exists index(:crdt_update_log, [:user_id], concurrently: true)
    drop_if_exists index(:note_revisions, [:user_id], concurrently: true)
    drop_if_exists index(:note_revisions, [:vault_id], concurrently: true)
  end

  def down do
    create_if_not_exists index(:crdt_update_log, [:user_id], concurrently: true)
    create_if_not_exists index(:note_revisions, [:user_id], concurrently: true)
    create_if_not_exists index(:note_revisions, [:vault_id], concurrently: true)
  end
end
