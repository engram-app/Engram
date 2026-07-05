defmodule Engram.Repo.Migrations.GrantVaultDeviceCursorsExpand do
  use Ecto.Migration

  # phase/expand: pure GRANT, no schema change.
  #
  # vault_device_cursors (priv/repo/migrations/20260616130000_cursor_pull_expand.exs)
  # was created without the sibling GRANT every other no-default-privileges
  # table carries (see idempotency_keys/processed_webhook_events expand
  # migrations). Every write to it runs as `engram_app` via `Repo.with_tenant`
  # (Engram.Sync.record_cursor/4), so the missing grant makes that write fail
  # with permission denied, which 500s `GET /sync/changes` for any client that
  # sends `X-Device-Id`, i.e. every real client on reconnect/focus catch-up.
  def up do
    execute "GRANT SELECT, INSERT, UPDATE, DELETE ON vault_device_cursors TO engram_app"
  end

  def down do
    execute "REVOKE ALL ON vault_device_cursors FROM engram_app"
  end
end
