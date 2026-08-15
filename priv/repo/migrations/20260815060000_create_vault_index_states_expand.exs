defmodule Engram.Repo.Migrations.CreateVaultIndexStatesExpand do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # phase/expand — new table, no backfill. Holds ONE encrypted Yjs snapshot per
  # vault: the `filemeta_v0` index doc (#1150) that #1151 makes durable.
  #
  # A separate table rather than columns on `vaults` because the blob is large
  # (#1149 measures ~2.0 MB for a churned 10k-note index) and the vaults row is
  # loaded on essentially every vault-scoped request. There is no
  # select-exclusion pattern in this codebase, so parking a multi-megabyte
  # column there would ride along on all of them. Here it is read only when an
  # index room binds and written only when one exits.
  #
  # RLS mirrors crdt_update_log / notes — tenant-scoped by user_id.
  def change do
    create table(:vault_index_states, primary_key: false) do
      add :vault_id, references(:vaults, type: :uuid, on_delete: :delete_all), primary_key: true

      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :state_ciphertext, :binary, null: false
      add :state_nonce, :binary, null: false

      # Always AAD-bound (aad_for_row(:vault_index_states, :state, vault_id)) —
      # there are no legacy empty-AAD rows to distinguish, since the table is
      # born after that migration. Carried anyway so UserDekRotation's sweep can
      # stamp it exactly like every other encrypted table.
      add :dek_version, :integer, null: false, default: 2

      timestamps(type: :timestamptz)
    end

    # user_id is the RLS predicate on every row, and an on_delete: :delete_all
    # FK (cascade scans). vault_id needs no separate index — it is the PK.
    create index(:vault_index_states, [:user_id])

    execute(
      "ALTER TABLE vault_index_states ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE vault_index_states DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE vault_index_states FORCE ROW LEVEL SECURITY",
      "ALTER TABLE vault_index_states NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_vault_index_states ON vault_index_states
        USING (user_id::text = (SELECT current_setting('app.current_tenant', true)))
        WITH CHECK (user_id::text = (SELECT current_setting('app.current_tenant', true)))
      """,
      "DROP POLICY IF EXISTS tenant_isolation_vault_index_states ON vault_index_states"
    )

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON vault_index_states TO engram_app",
      "REVOKE ALL ON vault_index_states FROM engram_app"
    )
  end
end
