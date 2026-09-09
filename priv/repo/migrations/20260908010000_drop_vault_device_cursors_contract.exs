defmodule Engram.Repo.Migrations.DropVaultDeviceCursorsContract do
  use Ecto.Migration

  @moduledoc """
  phase/contract: `vault_device_cursors` has had zero readers or writers since
  #1036 (2026-07-18) deleted `Engram.Sync.record_cursor/4` and the REST
  `GET /sync/changes` endpoint that called it, without porting the write to
  the socket-based `crdt_catchup_since` catch-up path that replaced it.
  `Engram.Sync.DeviceCursor` (the schema module) is deleted in this same PR.

  See `docs/context/sync-protocol.md` for the full history.
  """

  def up do
    drop table(:vault_device_cursors)
  end

  def down do
    create table(:vault_device_cursors, primary_key: false) do
      add :vault_id, references(:vaults, type: :uuid, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :device_id, :text, null: false, primary_key: true
      add :last_seq, :bigint, null: false, default: 0
      add :last_seen_at, :timestamptz, null: false
    end

    execute "GRANT SELECT, INSERT, UPDATE, DELETE ON vault_device_cursors TO engram_app"
  end
end
