defmodule EngramWeb.Plugs.BumpActivity do
  @moduledoc """
  Stamps `usage_meters.last_active_at` on every authenticated request so the
  inactivity cron (§C) can tell who's actually using Engram.

  Debounced: only writes when the stored value is stale by > 1h, since
  every API call and SSE keepalive otherwise hammers the meter row.

  An `ActivityCache` (per-node ETS) holds the last-known stamp so that, once
  warm, a request within the debounce window skips the meter read entirely —
  the common steady-state path no longer touches the DB at all. On a cache
  miss we fall back to the authoritative DB read, then warm the cache.
  """

  alias Engram.UsageMeters
  alias Engram.UsageMeters.ActivityCache

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: %{id: user_id}}} = conn, _opts) do
    case ActivityCache.get(user_id) do
      {:ok, ts} ->
        if needs_bump?(ts), do: bump(user_id)

      :miss ->
        last = UsageMeters.last_active_at(user_id)

        if needs_bump?(last) do
          bump(user_id)
        else
          ActivityCache.put(user_id, last)
        end
    end

    conn
  end

  def call(conn, _opts), do: conn

  defp bump(user_id) do
    now = DateTime.utc_now()
    UsageMeters.bump_last_active(user_id)
    ActivityCache.put(user_id, now)
  end

  defp needs_bump?(nil), do: true

  defp needs_bump?(%DateTime{} = ts) do
    DateTime.diff(DateTime.utc_now(), ts, :second) > ActivityCache.debounce_seconds()
  end
end
