defmodule Engram.Repo.Migrations.AddOauthClientAuthMethodsSupported do
  use Ecto.Migration

  # Expand-only: one nullable column, no backfill, no default.
  #
  # A CIMD document declares a PREFERRED method in `token_endpoint_auth_method`
  # and the full permitted set in `token_endpoint_auth_methods_supported`.
  # ChatGPT publishes `private_key_jwt` as the former and `["none",
  # "private_key_jwt"]` as the latter, then authenticates as a public client
  # over PKCE. Storing only the preferred method made that a terminal
  # `invalid_client`, because nothing on the row recorded that `none` was
  # allowed.
  #
  # NULL is meaningful here and is NOT the same as `{}`: a row written before
  # this column existed never had the set read off its document, while `{}`
  # means the document named nothing we support. The former must keep demanding
  # an assertion rather than silently widening on a guess; it repopulates on the
  # next document refetch.
  def change do
    alter table(:oauth_clients) do
      add :token_endpoint_auth_methods_supported, {:array, :text}
    end
  end
end
