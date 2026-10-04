defmodule EngramWeb.Admin.TelemetryController do
  @moduledoc """
  Self-host admin view of the install census: the operator's answer, whether the
  environment overrides it, and the exact payload that would be sent.
  """
  use EngramWeb, :controller

  alias Engram.Instance
  alias Engram.Telemetry.Heartbeat

  def show(conn, _params), do: json(conn, state())

  def update(conn, %{"enabled" => enabled}) when is_boolean(enabled) do
    {:ok, _} = Instance.set_telemetry_enabled(enabled)
    json(conn, state())
  end

  def update(conn, _params) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_enabled"})
  end

  defp state do
    %{
      telemetry_enabled: Instance.telemetry_enabled(),
      env_disabled: Heartbeat.env_disabled?(),
      payload: Heartbeat.payload()
    }
  end
end
