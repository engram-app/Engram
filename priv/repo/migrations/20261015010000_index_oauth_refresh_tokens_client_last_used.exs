defmodule Engram.Repo.Migrations.IndexOauthRefreshTokensClientLastUsed do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Serves the CIMD JWKS sweep's active-client filter (Engram.Workers.CimdRefresh):
  # an EXISTS on a client's recently used tokens and its max(last_used_at).
  # Without it every 5-minute sweep scanned the whole table (#1974).
  def change do
    create index(:oauth_refresh_tokens, [:client_id, :last_used_at], concurrently: true)
  end
end
