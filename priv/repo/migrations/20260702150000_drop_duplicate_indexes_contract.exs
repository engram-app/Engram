defmodule Engram.Repo.Migrations.DropDuplicateIndexesContract do
  use Ecto.Migration

  # phase/contract — drops redundant duplicate indexes (2026-07-02 audit, #863).
  #
  # Each was a strict leading-column prefix of a wider index — pure write
  # amplification on the hottest tables (chunks are bulk delete+insert on
  # every re-embed; every note edit is a non-HOT update):
  #   idx_chunks_note (note_id)          ⊂ chunks_note_id_position_index
  #   notes_vault_id_index (vault_id)    ⊂ notes_vault_id_seq_id_index
  #   attachments_vault_id_index         ⊂ attachments_vault_id_seq_id_index
  #
  # DROP INDEX CONCURRENTLY cannot run in a transaction, so this migration is
  # non-transactional — every statement is IF EXISTS so a partial failure
  # re-runs cleanly (reentrancy: no unguarded DDL in a non-txn migration).
  # The CHECK-constraint hardening lives in the NEXT migration, which runs
  # inside a normal transaction.

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("DROP INDEX CONCURRENTLY IF EXISTS idx_chunks_note")
    execute("DROP INDEX CONCURRENTLY IF EXISTS notes_vault_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS attachments_vault_id_index")
  end

  def down do
    execute("CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_chunks_note ON chunks (note_id)")

    execute("CREATE INDEX CONCURRENTLY IF NOT EXISTS notes_vault_id_index ON notes (vault_id)")

    execute(
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS attachments_vault_id_index ON attachments (vault_id)"
    )
  end
end
