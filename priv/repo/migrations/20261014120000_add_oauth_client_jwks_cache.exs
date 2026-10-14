defmodule Engram.Repo.Migrations.AddOauthClientJwksCache do
  use Ecto.Migration

  # Expand-only: two nullable columns, no backfill, no default (#1974).
  #
  # The last JWKS we fetched and verified for a CIMD client, and when. A new
  # node or a fresh deploy loads it instead of fetching on the token path, and
  # a vendor whose JWKS endpoint is failing keeps working on its last good
  # keys for up to 7 days. Public keys only, so nothing here is secret.
  #
  # NULL means "never fetched", and the next fetch fills it.
  def change do
    alter table(:oauth_clients) do
      add :jwks_cached, :map
      add :jwks_fetched_at, :utc_datetime
    end
  end
end
