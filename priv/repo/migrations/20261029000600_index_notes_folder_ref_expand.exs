defmodule Engram.Repo.Migrations.IndexNotesFolderRefExpand do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # The notes of a folder (NOT partial: the FK's ON DELETE SET NULL action runs
  # `WHERE vault_id = $1 AND folder_ref_id = $2` with no deleted_at predicate, and a
  # partial index would let it seq-scan the table on every hard-deleted folder row).
  def up do
    # A CONCURRENTLY build that fails leaves an INVALID index under its name;
    # dropping the name first makes the retry rebuild it.
    drop_if_exists index(:notes, [:vault_id, :folder_ref_id],
                     name: :notes_folder_ref,
                     concurrently: true
                   )

    create index(:notes, [:vault_id, :folder_ref_id],
             name: :notes_folder_ref,
             concurrently: true
           )
  end

  def down do
    drop_if_exists index(:notes, [:vault_id, :folder_ref_id],
                     name: :notes_folder_ref,
                     concurrently: true
                   )
  end
end
