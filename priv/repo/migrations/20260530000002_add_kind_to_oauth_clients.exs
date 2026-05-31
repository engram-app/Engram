defmodule Engram.Repo.Migrations.AddKindToOauthClients do
  use Ecto.Migration

  def change do
    alter table(:oauth_clients) do
      add :kind, :string, null: false, default: "mcp"
      add :first_user_agent, :text
      add :first_ip, :text
    end

    create constraint(:oauth_clients, :oauth_clients_kind_check,
             check: "kind IN ('mcp', 'obsidian')"
           )
  end
end

# Throwaway test: deliberate in-place edit to verify migrations-immutable lint blocks (DO NOT MERGE)
