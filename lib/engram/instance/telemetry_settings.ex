defmodule Engram.Instance.TelemetrySettings do
  @moduledoc """
  Singleton row (sentinel id, see `Engram.Instance`) holding the self-host
  census state: the random install id and the operator's tri-state answer.
  Deliberately separate from `instance_settings`; see the migration.
  """
  use Engram.Schema

  schema "instance_telemetry" do
    field :install_id, Ecto.UUID
    field :telemetry_enabled, :boolean
    timestamps(type: :utc_datetime)
  end
end
