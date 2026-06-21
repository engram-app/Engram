defmodule Engram.Repo.Migrations.CreateUsageBuckets do
  use Ecto.Migration

  # System table (NO RLS policy): operational rate-limit state keyed by
  # user_id (uuid) + kind. Same convention as usage_meters / user_limit_overrides
  # — written via raw Repo.query outside tenant scope. tokens/last_refill_at are
  # intentionally unindexed so updates are HOT (heap-only) and don't churn an
  # index on every spend.
  def change do
    create table(:usage_buckets, primary_key: false) do
      add :user_id, :uuid, null: false, primary_key: true
      add :kind, :text, null: false, primary_key: true
      add :tokens, :"double precision", null: false
      add :last_refill_at, :timestamptz, null: false
    end

    # No FK to users: hot-write operational table, no per-insert FK check.
    # Orphan rows are harmless (self-refilling, throwaway) — account deletion
    # cleanup and/or an Oban prune removes them. No ENABLE/FORCE ROW LEVEL
    # SECURITY and no CREATE POLICY — system table.
    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON usage_buckets TO engram_app",
      "REVOKE ALL ON usage_buckets FROM engram_app"
    )
  end
end
