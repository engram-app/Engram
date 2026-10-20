defmodule Engram.Repo.Migrations.AddOauthAuthorizationCodeDevice do
  use Ecto.Migration

  # Expand-only: one nullable column, no backfill, no default.
  #
  # The consent browser's `Engram.Analytics.Device` bucket ("mobile" |
  # "desktop" | "unknown"), so a code that expires unredeemed can be counted
  # by device (`engram_prom_ex_oauth_code_expired_total`). Codes live ten
  # minutes, so rows from before this column read NULL briefly and count as
  # "unknown"; nothing to backfill.
  def change do
    alter table(:oauth_authorization_codes) do
      add :device, :string
    end
  end
end
