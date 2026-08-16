defmodule Engram.Repo.Migrations.CreateVaultIndexUpdateLogExpand do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # phase/expand — new table, no backfill. The per-update tail for a vault's
  # `filemeta_v0` index room, mirroring `crdt_update_log` for note rooms.
  #
  # #1391. `vault_index_states` is snapshot-only, written when a room exits.
  # That was a sound trade while the `notes` rows were authoritative for paths:
  # losing a checkpoint interval left the index STALE and the rows still held
  # the truth. #1151 step 2 made the MAP authoritative and derives the path
  # columns from it, so an interval lost to a SIGKILL, a node loss or an ECS
  # task replacement now drops committed path CLAIMS — and the rows converge
  # back to the superseded snapshot on the next projection run.
  #
  # Volume is nothing like the note tail: index writes are rename/create/delete,
  # not keystrokes, and the checkpoint prunes what it folds in.
  #
  # RLS mirrors crdt_update_log / vault_index_states — tenant-scoped by user_id.
  def change do
    create table(:vault_index_update_log, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")

      add :vault_id, references(:vaults, type: :uuid, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false

      add :update_ciphertext, :binary, null: false
      add :update_nonce, :binary, null: false

      # Always AAD-bound (aad_for_row(:vault_index_update_log, :update, id)).
      # Carried so UserDekRotation's sweep stamps it like every other encrypted
      # table.
      add :dek_version, :integer, null: false, default: 2

      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    # Replay order is (vault_id, inserted_at, id): the id tiebreak matters
    # because two updates can land inside one clock tick, and Yjs updates are
    # commutative but the PRUNE is by exact id — an ordering tie must not make
    # replay and prune disagree about which rows a checkpoint folded in.
    create index(:vault_index_update_log, [:vault_id, :inserted_at, :id])

    # RLS predicate, and the on_delete: :delete_all cascade scans it.
    create index(:vault_index_update_log, [:user_id])

    execute(
      "ALTER TABLE vault_index_update_log ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE vault_index_update_log DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE vault_index_update_log FORCE ROW LEVEL SECURITY",
      "ALTER TABLE vault_index_update_log NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_vault_index_update_log ON vault_index_update_log
        USING (user_id::text = (SELECT current_setting('app.current_tenant', true)))
        WITH CHECK (user_id::text = (SELECT current_setting('app.current_tenant', true)))
      """,
      "DROP POLICY IF EXISTS tenant_isolation_vault_index_update_log ON vault_index_update_log"
    )

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON vault_index_update_log TO engram_app",
      "REVOKE ALL ON vault_index_update_log FROM engram_app"
    )
  end
end
