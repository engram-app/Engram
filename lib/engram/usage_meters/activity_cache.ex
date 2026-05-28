defmodule Engram.UsageMeters.ActivityCache do
  @moduledoc """
  Cache of the last time we stamped `usage_meters.last_active_at` for a user.
  Lets `EngramWeb.Plugs.BumpActivity` skip the per-request meter read once it
  knows the user was bumped within the debounce window.

  Two backends, selected by `Engram.Cache.backend/0`:

    * `:ets`   — per-node `:public` table (default; self-host). The cached value
      is a non-secret timestamp, so request processes read/write it directly
      with no GenServer hop. This process owns the table for the app's lifetime.
      Entries are tiny and bounded by the active-user count, so no sweep is
      needed. On node restart the table is empty, so each user triggers one
      cold-path meter read again — harmless and self-healing. Per-node, so on
      multi-node a user hitting N nodes bumps the meter up to N× per window.

    * `:redis` — cluster-shared (SaaS). One key `activity:{user_id}` with a TTL
      equal to the debounce window, so the debounce is exact across all nodes
      and key expiry *is* the window. Fails open to `:miss` (→ DB read-through).

  If the owning ETS process is down and the table is absent, reads/writes
  degrade to `:miss`/no-op rather than raising, so a cache outage falls back to
  the authoritative DB read instead of failing the request.
  """

  use GenServer

  alias Engram.Cache

  @table :engram_activity_cache

  # Redis TTL for the activity key. Must be >= the BumpActivity debounce window
  # (3600s): the entry only needs to survive the window, and expiry naturally
  # re-arms the cold-path meter read. A longer TTL would just retain a stale
  # timestamp that the caller's `>` comparison already treats as "needs bump".
  @redis_ttl_seconds 3600

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec get(user_id :: integer()) :: {:ok, DateTime.t()} | :miss
  def get(user_id) do
    case Cache.backend() do
      :redis -> redis_get(user_id)
      _ -> ets_get(user_id)
    end
  end

  @spec put(user_id :: integer(), last_active_at :: DateTime.t()) :: :ok
  def put(user_id, %DateTime{} = last_active_at) do
    case Cache.backend() do
      :redis ->
        Cache.redis_set(key(user_id), DateTime.to_iso8601(last_active_at), @redis_ttl_seconds)

      _ ->
        ets_put(user_id, last_active_at)
    end
  end

  defp redis_get(user_id) do
    with {:ok, iso} <- Cache.redis_get(key(user_id)),
         {:ok, ts, _offset} <- DateTime.from_iso8601(iso) do
      {:ok, ts}
    else
      _ -> :miss
    end
  end

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

  defp key(user_id), do: "activity:#{user_id}"

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
