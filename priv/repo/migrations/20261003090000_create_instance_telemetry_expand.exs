defmodule Engram.Repo.Migrations.CreateInstanceTelemetryExpand do
  use Ecto.Migration

  # phase/expand — self-host install census state, a singleton row. Its own
  # table (not instance_settings) on purpose: the daily ping can create this row
  # before any admin exists, and an instance_settings row created that early
  # would bake in a registration_mode and freeze ENGRAM_DEFAULT_REGISTRATION_MODE.
  #
  # `install_id` is a random uuid, never derived from host data.
  # `telemetry_enabled` is tri-state: NULL = operator never answered (the ping
  # counts as on), true = acknowledged, false = turned off.
  # :timestamptz per Squawk's prefer-timestamp-tz; the schema keeps :utc_datetime.
  def change do
    create table(:instance_telemetry, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :install_id, :uuid, null: false
      add :telemetry_enabled, :boolean
      add :inserted_at, :timestamptz, null: false
      add :updated_at, :timestamptz, null: false
    end
  end
end
