defmodule Engram.Repo.Migrations.AddUserSuspendedAt do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # timestamptz (squawk prefer-timestamp-tz). The User schema field stays
      # `:utc_datetime_usec` — Ecto reads/writes DateTime values either way.
      add :suspended_at, :timestamptz
    end
  end
end
