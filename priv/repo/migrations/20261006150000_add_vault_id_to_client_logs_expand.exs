defmodule Engram.Repo.Migrations.AddVaultIdToClientLogsExpand do
  use Ecto.Migration

  # phase/expand — nullable column, FK, index. No backfill (engram-app/Engram#1866).
  #
  # `GET /api/logs` filtered on user only, so a credential restricted to vault A
  # read log lines from every vault. Ingest now stamps the request's vault and
  # the read filters on it. Legacy rows stay NULL and are simply never returned;
  # ClientLogsPruner ages them out within the 30-day retention window.
  #
  # FK is added NOT VALID then validated as a separate statement so the add
  # takes no long lock. The validate scan is cheap: every existing row is NULL.
  #
  # One index, (vault_id, ts): leading vault_id covers the FK (incl. its ON
  # DELETE CASCADE, splinter's unindexed_foreign_keys) and serves the read,
  # `user_id = ? AND vault_id = ? ORDER BY ts DESC`. A vault belongs to exactly
  # one user, so prefixing user_id would add width without selectivity.

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    alter table(:client_logs) do
      add :vault_id, :uuid
    end

    execute """
    ALTER TABLE client_logs
      ADD CONSTRAINT client_logs_vault_id_fkey
      FOREIGN KEY (vault_id) REFERENCES vaults(id) ON DELETE CASCADE NOT VALID
    """

    execute "ALTER TABLE client_logs VALIDATE CONSTRAINT client_logs_vault_id_fkey"

    create index(:client_logs, [:vault_id, :ts], concurrently: true)
  end

  def down do
    drop index(:client_logs, [:vault_id, :ts], concurrently: true)

    alter table(:client_logs) do
      remove :vault_id
    end
  end
end
