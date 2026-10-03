defmodule Engram.Repo.Migrations.AddInstanceTelemetryExpand do
  use Ecto.Migration

  # phase/expand — self-host install census. `install_id` is a random uuid
  # minted on first use (never derived from host data); `telemetry_enabled` is
  # tri-state: NULL = operator not asked yet, true/false = their answer.
  def change do
    alter table(:instance_settings) do
      add :install_id, :uuid
      add :telemetry_enabled, :boolean
    end
  end
end
