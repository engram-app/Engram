defmodule Engram.Repo.Migrations.IndexNoteTombstonesByPath do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Tombstones by path. The live path index is partial on `deleted_at IS NULL`,
  # so the two lookups that read tombstones at a path scanned every tombstone in
  # the vault: the delete-wins resurrection check (`Notes.recently_deleted_twin?/4`,
  # on every upsert to a path) and the rename link rewrite's old-path recovery
  # (`RewriteNoteLinks.tombstone_old_path/4`). Every rename and delete adds a
  # tombstone and none is purged yet, so that scan only grows.
  # NotesPathIndexPlanTest pins the plan.
  def up do
    # A CONCURRENTLY build that fails (lock timeout, deploy kill) leaves an
    # INVALID index under its name, which a retry would skip or trip on.
    # Dropping the name first makes the retry rebuild it.
    drop_if_exists index(:notes, [], name: :notes_vault_path_tombstone_index, concurrently: true)

    create index(:notes, [:vault_id, :path_hmac],
             name: :notes_vault_path_tombstone_index,
             where: "deleted_at IS NOT NULL",
             concurrently: true
           )
  end

  def down do
    drop_if_exists index(:notes, [], name: :notes_vault_path_tombstone_index, concurrently: true)
  end
end
