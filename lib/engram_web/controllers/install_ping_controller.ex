defmodule EngramWeb.InstallPingController do
  @moduledoc """
  Public collector for the self-host install census. Only the SaaS instance
  collects; a self-host instance answers 404. Unauthenticated and rate-limited
  (`:rate_limit_auth`); the payload is a fixed, validated shape.
  """
  use EngramWeb, :controller

  alias Engram.Telemetry.InstallPings

  def create(conn, params) do
    if Application.get_env(:engram, :billing_enabled, false) do
      case InstallPings.record(params) do
        {:ok, _ping} ->
          send_resp(conn, 204, "")

        {:error, _changeset} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_ping"})
      end
    else
      conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end
end
