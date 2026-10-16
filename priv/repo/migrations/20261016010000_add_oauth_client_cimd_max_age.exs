defmodule Engram.Repo.Migrations.AddOauthClientCimdMaxAge do
  use Ecto.Migration

  # Expand-only: one nullable column, no backfill, no default (#1977).
  #
  # The `Cache-Control: max-age` a CIMD document was served with, in seconds.
  # `Engram.OAuth.Cimd` clamps it to [5 min, 24 h] when deciding freshness.
  # NULL means the vendor sent none, and the 24 h default applies.
  def change do
    alter table(:oauth_clients) do
      add :cimd_max_age, :bigint
    end
  end
end
