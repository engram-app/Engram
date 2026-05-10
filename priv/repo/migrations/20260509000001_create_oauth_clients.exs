defmodule Engram.Repo.Migrations.CreateOauthClients do
  use Ecto.Migration

  def change do
    create table(:oauth_clients, primary_key: false) do
      add :client_id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :client_secret_hash, :string
      add :redirect_uris, {:array, :string}, null: false, default: []
      add :client_name, :string
      add :scope, :string

      add :grant_types, {:array, :string},
        null: false,
        default: ["authorization_code", "refresh_token"]

      add :response_types, {:array, :string}, null: false, default: ["code"]
      add :token_endpoint_auth_method, :string, null: false, default: "none"
      add :software_id, :string
      add :software_version, :string

      timestamps(type: :utc_datetime_usec)
    end
  end
end
