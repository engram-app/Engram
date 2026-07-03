defmodule Engram.Repo.Migrations.AddConnIdToClientLogs do
  use Ecto.Migration

  def change do
    alter table(:client_logs) do
      add :conn_id, :string
      add :device_id, :string
    end
  end
end
