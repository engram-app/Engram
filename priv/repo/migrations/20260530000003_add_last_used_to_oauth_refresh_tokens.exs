defmodule Engram.Repo.Migrations.AddLastUsedToOauthRefreshTokens do
  use Ecto.Migration

  def change do
    alter table(:oauth_refresh_tokens) do
      add :last_used_at, :utc_datetime_usec
      add :last_used_ip, :text
    end
  end
end
