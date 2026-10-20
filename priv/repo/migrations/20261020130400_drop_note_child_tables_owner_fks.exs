defmodule Engram.Repo.Migrations.DropNoteChildTablesOwnerFks do
  use Ecto.Migration

  # crdt_update_log and note_revisions rows belong to a note, whose note_id FK
  # cascades (note -> vault -> user), so their user_id and vault_id FKs only
  # repeated it: two extra FK checks (index probes of users and vaults) on
  # every CRDT append, and an index each to back them. The columns stay: RLS
  # and the tenant filters read them. NoteChildTablesFkTest proves the vault
  # and account deletes still remove the rows.
  #
  # Indexes: crdt_update_log (user_id), note_revisions (user_id) and
  # (vault_id) go with their FKs (3 and 4 prod scans for the revision ones;
  # the log's user index served only per-user discovery over a table pruned
  # at every checkpoint). crdt_update_log (vault_id) stays: the sync
  # quiescence endpoint counts a vault's pending updates by it.
  #
  # Dropping an FK takes ACCESS EXCLUSIVE on its table and a lock on the
  # referenced one. Catalog-only, but lock_timeout makes a busy table fail
  # the migration (the release retries on the next boot) rather than queue
  # every writer behind it. SET LOCAL: it ends with this transaction.
  def up do
    execute "SET LOCAL lock_timeout = '5s'"
    drop constraint(:crdt_update_log, "crdt_update_log_user_id_fkey")
    drop constraint(:crdt_update_log, "crdt_update_log_vault_id_fkey")
    drop constraint(:note_revisions, "note_revisions_user_id_fkey")
    drop constraint(:note_revisions, "note_revisions_vault_id_fkey")
    drop_if_exists index(:crdt_update_log, [:user_id])
    drop_if_exists index(:note_revisions, [:user_id])
    drop_if_exists index(:note_revisions, [:vault_id])
  end

  def down do
    create_if_not_exists index(:crdt_update_log, [:user_id])
    create_if_not_exists index(:note_revisions, [:user_id])
    create_if_not_exists index(:note_revisions, [:vault_id])

    for {table, col, ref} <- [
          {"crdt_update_log", "user_id", "users"},
          {"crdt_update_log", "vault_id", "vaults"},
          {"note_revisions", "user_id", "users"},
          {"note_revisions", "vault_id", "vaults"}
        ] do
      execute """
      ALTER TABLE #{table} ADD CONSTRAINT #{table}_#{col}_fkey
        FOREIGN KEY (#{col}) REFERENCES #{ref}(id) ON DELETE CASCADE NOT VALID
      """

      execute "ALTER TABLE #{table} VALIDATE CONSTRAINT #{table}_#{col}_fkey"
    end
  end
end
