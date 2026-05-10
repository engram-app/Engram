defmodule Engram.Repo.Migrations.CreateOauthAuthorizationCodes do
  use Ecto.Migration

  def change do
    create table(:oauth_authorization_codes) do
      add :code_hash, :string, null: false
      add :client_id, :uuid, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :redirect_uri, :string, null: false
      add :code_challenge, :string, null: false
      add :code_challenge_method, :string, null: false, default: "S256"
      add :scope, :string
      add :vault_id, references(:vaults, on_delete: :delete_all)
      add :state, :string
      add :expires_at, :utc_datetime, null: false
      add :consumed_at, :utc_datetime

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:oauth_authorization_codes, [:code_hash])
    create index(:oauth_authorization_codes, [:user_id])
    create index(:oauth_authorization_codes, [:client_id])
    create index(:oauth_authorization_codes, [:expires_at])
  end
end
