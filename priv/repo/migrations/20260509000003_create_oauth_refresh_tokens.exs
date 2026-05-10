defmodule Engram.Repo.Migrations.CreateOauthRefreshTokens do
  use Ecto.Migration

  def change do
    create table(:oauth_refresh_tokens) do
      add :token_hash, :string, null: false
      add :family_id, :uuid, null: false
      add :client_id, :uuid, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :vault_id, references(:vaults, on_delete: :delete_all)
      add :scope, :string
      add :expires_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime
      add :consumed_at, :utc_datetime

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:oauth_refresh_tokens, [:token_hash])
    create index(:oauth_refresh_tokens, [:family_id])
    create index(:oauth_refresh_tokens, [:user_id])
    create index(:oauth_refresh_tokens, [:expires_at])
  end
end
