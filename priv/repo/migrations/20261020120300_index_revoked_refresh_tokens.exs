defmodule Engram.Repo.Migrations.IndexRevokedRefreshTokens do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # The token cleanups (CleanupDeviceAuthWorker, every 15 minutes) filtered
  # revoked rows with no index on revoked_at, so each run seq-scanned both
  # token tables, and they grow with every 15-minute rotation. Each predicate
  # below is the cleanup's own, so the planner can use the index:
  #
  #   * OAuth `cleanup_expired/0` reaped_families and `backfill_superseded/0`:
  #     revoked_at IS NOT NULL AND superseded_at IS NULL.
  #   * DeviceFlow revoked rows: revoked_at IS NOT NULL.
  #   * DeviceFlow expired, never-rotated rows: revoked_at IS NULL, by
  #     expires_at. Only live heads are in it, so it stays small.
  def change do
    create index(:oauth_refresh_tokens, [:revoked_at],
             name: :oauth_refresh_tokens_revoked_at_index,
             where: "revoked_at IS NOT NULL AND superseded_at IS NULL",
             concurrently: true
           )

    create index(:device_refresh_tokens, [:revoked_at],
             name: :device_refresh_tokens_revoked_at_index,
             where: "revoked_at IS NOT NULL",
             concurrently: true
           )

    create index(:device_refresh_tokens, [:expires_at],
             name: :device_refresh_tokens_unrevoked_expires_at_index,
             where: "revoked_at IS NULL",
             concurrently: true
           )
  end
end
