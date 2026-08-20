defmodule EngramWeb.Plugs.BumpActivity do
  @moduledoc """
  Stamps `usage_meters.last_active_at` on every authenticated request so the
  inactivity cron (§C) can tell who's actually using Engram.

  The debounce + cache logic lives in `Engram.UsageMeters.touch_active/1`
  because HTTP is not the only transport a user can be active on — the
  `sync:`/`crdt:` channel joins call it too via `EngramWeb.ChannelGate`.
  Stamping on requests alone let a plugin user who syncs daily over WebSocket
  and rarely touches REST age into the 90-day soft-delete sweep while in
  constant active use.
  """

  alias Engram.UsageMeters

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: %{id: user_id}}} = conn, _opts) do
    :ok = UsageMeters.touch_active(user_id)
    conn
  end

  def call(conn, _opts), do: conn
end
