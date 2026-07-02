defmodule Engram.Repo.Migrations.DbHygieneIndexesChecksContract do
  use Ecto.Migration

  # phase/contract — drops redundant duplicate indexes; also hardens
  # subscriptions with CHECK constraints (2026-07-02 audit, #863).
  #
  # Index drops (write amplification on the hottest tables — every non-HOT
  # note edit maintained all of these for zero read benefit):
  #   idx_chunks_note (note_id)          ⊂ chunks_note_id_position_index
  #   notes_vault_id_index (vault_id)    ⊂ notes_vault_id_seq_id_index
  #   attachments_vault_id_index         ⊂ attachments_vault_id_seq_id_index
  #
  # subscriptions.tier/status previously relied on app-side
  # validate_inclusion only — webhook-driven writes are exactly where a
  # surprising vendor value can slip in. Value sets mirror
  # Engram.Billing.Subscription.changeset/2.

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("DROP INDEX CONCURRENTLY IF EXISTS idx_chunks_note")
    execute("DROP INDEX CONCURRENTLY IF EXISTS notes_vault_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS attachments_vault_id_index")

    execute("""
    ALTER TABLE subscriptions ADD CONSTRAINT subscriptions_tier_check
      CHECK (tier IN ('free','starter','pro')) NOT VALID
    """)

    execute("ALTER TABLE subscriptions VALIDATE CONSTRAINT subscriptions_tier_check")

    execute("""
    ALTER TABLE subscriptions ADD CONSTRAINT subscriptions_status_check
      CHECK (status IN ('trialing','active','past_due','paused','canceled')) NOT VALID
    """)

    execute("ALTER TABLE subscriptions VALIDATE CONSTRAINT subscriptions_status_check")
  end

  def down do
    execute("ALTER TABLE subscriptions DROP CONSTRAINT IF EXISTS subscriptions_status_check")
    execute("ALTER TABLE subscriptions DROP CONSTRAINT IF EXISTS subscriptions_tier_check")

    execute("CREATE INDEX CONCURRENTLY idx_chunks_note ON chunks (note_id)")
    execute("CREATE INDEX CONCURRENTLY notes_vault_id_index ON notes (vault_id)")

    execute("CREATE INDEX CONCURRENTLY attachments_vault_id_index ON attachments (vault_id)")
  end
end
