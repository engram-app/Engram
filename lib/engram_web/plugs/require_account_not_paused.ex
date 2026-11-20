defmodule EngramWeb.Plugs.RequireAccountNotPaused do
  @moduledoc """
  Halts a quarantined user (`Engram.ClientGate.paused/1`) with
  `403 {"error": "account_paused"}`. The HTTP half; `EngramWeb.ChannelGate`
  enforces the same verdict on join.

  Placed AFTER `BumpActivity` on purpose, like `RequirePluginVersion`: a refused
  request must still stamp `last_active_at`, or `InactivityCleanup` soft-deletes
  a paused-but-active account at 90 days.
  """

  import Plug.Conn

  alias Engram.ClientGate
  alias EngramWeb.Plugs.Halt

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: user}} = conn, _opts) do
    case ClientGate.paused(user) do
      :ok ->
        conn

      {:error, %{reason: reason}} ->
        # An hour: the plugin probes hourly and a lift also drops its sockets.
        conn
        |> put_resp_header("retry-after", "3600")
        |> Halt.json(ClientGate.http_status(reason), %{error: reason})
    end
  end

  def call(conn, _opts), do: conn
end
