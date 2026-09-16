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
  # `:text`, not `:string` — Ecto renders the latter as `varchar(255)`, which
  # squawk's prefer-text-field rejects (resizing a varchar later takes an ACCESS
  # EXCLUSIVE lock). It is also just correct here: a `jwks_uri` is a vendor URL
  # with no useful 255-byte ceiling. The schema fields stay `:string`; that is
  # the Elixir type, independent of the column type, same as `first_ip`.
  def change do
    alter table(:oauth_clients) do
      add :jwks_uri, :text
      add :token_endpoint_auth_signing_alg, :text
    end
  end
end
