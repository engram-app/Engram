defmodule Engram.Repo.Migrations.AddOauthClientJwksExpand do
  use Ecto.Migration

  # Expand-only: two nullable columns, no backfill, no default.
  #
  # A CIMD client authenticating with `private_key_jwt` signs a client assertion
  # with a key published at its own `jwks_uri`. The token endpoint has to verify
  # that assertion, and `Engram.OAuth.get_client/1` is a pure DB read there by
  # design — network I/O stays on the interactive authorize path only. So the key
  # location has to live on the row rather than being re-derived from the
  # document at token time.
  def change do
    alter table(:oauth_clients) do
      add :jwks_uri, :string
      add :token_endpoint_auth_signing_alg, :string
    end
  end
end
