defmodule Engram.Repo.Migrations.AddDcrMetadataToOauthClients do
  use Ecto.Migration

  def change do
    alter table(:oauth_clients) do
      add :logo_uri, :text
      add :tos_uri, :text
      add :policy_uri, :text
    end
  end
end
