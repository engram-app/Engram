defmodule Engram.Repo.Migrations.CreateClientOriginStats do
  use Ecto.Migration

  # Pricing v2 §E — per-account daily breakdown of MCP request origins,
  # classified by user-agent. Daily-rollup grain keeps the row count bounded
  # (~10 classes × 90 days × N users) and powers both the operator Mix task
  # and the OriginAbuseSweep cron.
  def change do
    create table(:client_origin_stats, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all, type: :bigint), null: false
      add :day, :date, null: false
      add :fingerprint_class, :string, null: false
      add :request_count, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create unique_index(:client_origin_stats, [:user_id, :day, :fingerprint_class])
    create index(:client_origin_stats, [:day])
  end
end
