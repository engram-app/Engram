defmodule Engram.Repo.Migrations.AddConnIdToClientLogs do
  use Ecto.Migration

  def change do
    alter table(:client_logs) do
      add :conn_id, :text
      add :device_id, :text
    end
  end
end
