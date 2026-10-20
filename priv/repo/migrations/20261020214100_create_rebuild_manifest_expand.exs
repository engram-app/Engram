# priv/repo/migrations/20261020214100_create_rebuild_manifest_expand.exs
defmodule Engram.Repo.Migrations.CreateRebuildManifestExpand do
  use Ecto.Migration

  # phase/expand: new tables, no backfill. The v5 rebuild switch, manifest
  # and spend ledger (`Engram.Rebuild`, chunker v5 Task 16.1). Written only
  # while `INDEX_REBUILD` is `dry_run` or `on`; with it `off` nothing reads
  # or writes them.
  #
  # rebuild_manifest: one row per stale note, the dry run's estimate.
  # `dl_sum`/`dl_count` are its planned chunks' keyword lengths, summed per
  # vault into rebuild_manifest_vaults.avgdl, the BM25 avgdl pinned for the
  # whole pass (spec K2, H14).
  #
  # rebuild_ledger: one global row (no user_id, so no RLS, like
  # data_migrations). The budget (1.15x the manifest) and what the pass has
  # spent; `halted_at` set means the pass is off.
  #
  # The two tenant tables mirror embedding_cache: tenant-scoped on user_id,
  # ENABLE + FORCE, engram_app grants, plus the maintenance_all policy every
  # tenant table needs (Engram.Repo.MaintenanceRoleTest fails without it).
  # Their FK indexes are the next migration, CONCURRENTLY.
  def change do
    create table(:rebuild_manifest, primary_key: false) do
      add :note_id, references(:notes, type: :uuid, on_delete: :delete_all), primary_key: true

      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :vault_id, references(:vaults, type: :uuid, on_delete: :delete_all), null: false
      add :est_tokens, :bigint, null: false
      add :new_points, :bigint, null: false
      add :reused_points, :bigint, null: false
      add :mean_pooled_points, :bigint, null: false
      add :dl_sum, :bigint, null: false
      add :dl_count, :bigint, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create table(:rebuild_manifest_vaults, primary_key: false) do
      add :vault_id, references(:vaults, type: :uuid, on_delete: :delete_all), primary_key: true

      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :avgdl, :float, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create table(:rebuild_ledger, primary_key: false) do
      # One row: `Engram.Rebuild` only ever writes id = true.
      add :id, :boolean, primary_key: true, default: true
      add :budget_tokens, :bigint, null: false
      add :spent_tokens, :bigint, null: false, default: 0
      add :halted_at, :timestamptz
      add :updated_at, :timestamptz, null: false, default: fragment("now()")
    end

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON rebuild_ledger TO engram_app",
      "REVOKE ALL ON rebuild_ledger FROM engram_app"
    )

    for table <- ~w(rebuild_manifest rebuild_manifest_vaults) do
      execute(
        "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY",
        "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
      )

      execute(
        "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY",
        "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
      )

      execute(
        """
        CREATE POLICY tenant_isolation_#{table} ON #{table}
          USING (user_id::text = (SELECT current_setting('app.current_tenant', true)))
          WITH CHECK (user_id::text = (SELECT current_setting('app.current_tenant', true)))
        """,
        "DROP POLICY IF EXISTS tenant_isolation_#{table} ON #{table}"
      )

      execute(
        "CREATE POLICY maintenance_all ON #{table} TO engram_maintenance USING (true) WITH CHECK (true)",
        "DROP POLICY IF EXISTS maintenance_all ON #{table}"
      )

      execute(
        "GRANT SELECT, INSERT, UPDATE, DELETE ON #{table} TO engram_app",
        "REVOKE ALL ON #{table} FROM engram_app"
      )
    end
  end
end
