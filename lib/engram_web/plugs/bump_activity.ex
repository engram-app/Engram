defmodule EngramWeb.Plugs.BumpActivity do
  @moduledoc """
  Stamps `usage_meters.last_active_at` on every authenticated request so the
  inactivity cron (§C) can tell who's actually using Engram.

  Debounced: only writes when the stored value is stale by > 1h, since
  every API call and SSE keepalive otherwise hammers the meter row.
  """

  alias Engram.UsageMeters

  @debounce_seconds 3600

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: %{id: user_id}}} = conn, _opts) do
    last = UsageMeters.last_active_at(user_id)

    if needs_bump?(last) do
      UsageMeters.bump_last_active(user_id)
    end

    conn
  end

  def call(conn, _opts), do: conn

  defp needs_bump?(nil), do: true

  defp needs_bump?(%DateTime{} = ts) do
    DateTime.diff(DateTime.utc_now(), ts, :second) > @debounce_seconds
  end
end
