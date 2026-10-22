defmodule Engram.Repo.Migrations.CreateServiceOverridesExpand do
  use Ecto.Migration

  # phase/expand: new table, no backfill. Runtime overrides of an allowlist
  # of config keys (`Engram.ServiceConfig.Overrides`): the v5 rollout flags
  # and `:qdrant_active_cluster`, flipped from a remote shell in seconds
  # instead of a TF env change plus an ECS rollout. Empty = every key reads
  # its env value, exactly as before this table existed.
  #
  # Global, like rebuild_ledger and data_migrations: no user_id, so no RLS
  # and no maintenance_all policy (that policy is for tenant tables). The app
  # pool reads and writes it; the maintenance role gets DML through the
  # default privileges `Engram.Release.prepare_database/0` sets.
  def change do
    create table(:service_overrides, primary_key: false) do
      add :key, :text, primary_key: true
      add :value, :jsonb, null: false
      add :updated_by, :text, null: false
      add :updated_at, :timestamptz, null: false, default: fragment("now()")
    end

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON service_overrides TO engram_app",
      "REVOKE ALL ON service_overrides FROM engram_app"
    )
  end
end
