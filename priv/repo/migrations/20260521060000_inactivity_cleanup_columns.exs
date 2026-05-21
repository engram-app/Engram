defmodule Engram.Repo.Migrations.InactivityCleanupColumns do
  use Ecto.Migration

  # Pricing v2 §C — 90-day inactivity auto-delete for Free users.
  # Columns are intentionally idempotent flags + timestamps so the daily cron
  # is restart-safe: re-running a sweep that already fired its warning email
  # is a no-op.
  def change do
    alter table(:usage_meters) do
      add :last_active_at, :utc_datetime_usec
    end

    create index(:usage_meters, [:last_active_at])

    alter table(:users) do
      add :deleted_at, :utc_datetime_usec
      add :inactivity_warning_60_at, :utc_datetime_usec
      add :inactivity_warning_80_at, :utc_datetime_usec
    end

    create index(:users, [:deleted_at])
  end
end
