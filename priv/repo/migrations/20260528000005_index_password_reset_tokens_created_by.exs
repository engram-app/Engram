defmodule Engram.Repo.Migrations.IndexPasswordResetTokensCreatedBy do
  use Ecto.Migration

  # CREATE INDEX CONCURRENTLY can't run inside a transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Splinter flagged the FK `password_reset_tokens.created_by` as unindexed.
  # Matches the pattern set by the invites migration.
  def change do
    create index(:password_reset_tokens, [:created_by], concurrently: true)
  end
end
