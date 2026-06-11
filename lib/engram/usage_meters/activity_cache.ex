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

  # Canonical home of the activity-stamp debounce window. BumpActivity reads it
  # via debounce_seconds/0 so the plug's debounce and the Redis key TTL can't
  # drift apart.
  @debounce_seconds 3600

  # Redis TTL for the activity key == the debounce window: the entry only needs
  # to survive one window, and expiry re-arms the cold-path meter read. A longer
  # TTL would also be correct (the caller's `>` comparison treats an
  # over-retained stale timestamp as "needs bump"), but matching the window
  # keeps memory minimal.
  @redis_ttl_seconds @debounce_seconds

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "The activity-stamp debounce window, in seconds (single source of truth)."
  # No @spec: the body returns a compile-time literal, so Dialyzer's success
  # typing is the singleton `3600` and a `pos_integer()` spec is a rejected
  # supertype. The @doc documents intent without over-constraining.
  def debounce_seconds, do: @debounce_seconds

  @spec get(user_id :: Ecto.UUID.t()) :: {:ok, DateTime.t()} | :miss
  def get(user_id) do
    case Cache.backend() do
      :redis -> redis_get(user_id)
      _ -> ets_get(user_id)
    end
  end

  @spec put(user_id :: Ecto.UUID.t(), last_active_at :: DateTime.t()) :: :ok
  def put(user_id, %DateTime{} = last_active_at) do
    case Cache.backend() do
      :redis ->
        Cache.redis_set(
          :activity,
          key(user_id),
          DateTime.to_iso8601(last_active_at),
          @redis_ttl_seconds
        )

      _ ->
        ets_put(user_id, last_active_at)
    end
  end

  defp redis_get(user_id) do
    case Cache.redis_get(:activity, key(user_id)) do
      {:ok, iso} -> decode(iso)
      :miss -> :miss
    end
  end

  # Everything we write is valid ISO8601, so a parse failure means a corrupt or
  # foreign write — surface it as a distinct backend error (not a silent miss)
  # and fall back to the DB read-through. The next bump self-heals the key.
  defp decode(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, ts, _offset} ->
        {:ok, ts}

      _ ->
        Cache.report_backend_error(:activity, :get, :decode_error)
        :miss
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
