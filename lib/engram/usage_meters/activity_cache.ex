defmodule Engram.UsageMeters.ActivityCache do
  @moduledoc """
  Cache of the last time we stamped `usage_meters.last_active_at` for a user.
  Lets `EngramWeb.Plugs.BumpActivity` skip the per-request meter read once it
  knows the user was bumped within the debounce window.

  Backend: `:ets` — per-node `:public` table. The cached value is a non-secret
  timestamp, so request processes read/write it directly with no GenServer hop.
  This process owns the table for the app's lifetime. Entries are tiny and
  bounded by the active-user count, so no sweep is needed. On node restart the
  table is empty, so each user triggers one cold-path meter read again —
  harmless and self-healing. Per-node, so on multi-node a user hitting N nodes
  bumps the meter up to N× per window.

  If the owning ETS process is down and the table is absent, reads/writes
  degrade to `:miss`/no-op rather than raising, so a cache outage falls back to
  the authoritative DB read instead of failing the request.
  """

  use GenServer

  @table :engram_activity_cache

  # Canonical home of the activity-stamp debounce window. BumpActivity reads it
  # via debounce_seconds/0 so the plug's debounce stays in sync.
  @debounce_seconds 3600

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "The activity-stamp debounce window, in seconds (single source of truth)."
  # No @spec: the body returns a compile-time literal, so Dialyzer's success
  # typing is the singleton `3600` and a `pos_integer()` spec is a rejected
  # supertype. The @doc documents intent without over-constraining.
  def debounce_seconds, do: @debounce_seconds

  @spec get(user_id :: Ecto.UUID.t()) :: {:ok, DateTime.t()} | :miss
  def get(user_id), do: ets_get(user_id)

  @spec put(user_id :: Ecto.UUID.t(), last_active_at :: DateTime.t()) :: :ok
  def put(user_id, %DateTime{} = last_active_at), do: ets_put(user_id, last_active_at)

  defp ets_get(user_id) do
    case :ets.lookup(@table, user_id) do
      [{^user_id, %DateTime{} = ts}] -> {:ok, ts}
      [] -> :miss
    end
  rescue
    # Table absent (owner crashed/not yet started) → degrade to the DB path.
    ArgumentError -> :miss
  end

  defp ets_put(user_id, %DateTime{} = last_active_at) do
    :ets.insert(@table, {user_id, last_active_at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(:ok) do
    _ =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{}}
  end
end
