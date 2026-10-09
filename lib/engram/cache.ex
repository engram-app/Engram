defmodule Engram.Cache do
  @moduledoc """
  The node-local read-through cache. `fetch/3` answers from ETS or runs the
  loader and stores its result. Caches are declared in
  `Engram.Cache.Registry`; `Engram.Cache.Server` owns the tables and applies
  cluster (`Engram.Cluster.CacheSync`) and Postgres NOTIFY evictions.

  A loader runs in the caller's process, so it keeps the caller's tenant
  context (`Repo.with_tenant/2`); the cache never widens what a query sees.
  """

  alias Engram.Cache.Registry
  alias Engram.Cluster.CacheSync

  # A miss parks a `{@pending, token}` row under the key before running the
  # loader, and the loaded value replaces that row only if it is still there
  # (`:ets.select_replace/2` is an atomic compare-and-swap per object). An
  # eviction or clear that lands while the loader runs deletes the marker, so
  # the possibly stale value is returned to this caller but never stored.
  # Without it a revoked API key read just before its NOTIFY stays valid for
  # the whole TTL. Per key: an eviction of another key does not cost a put.
  # The key sits in the match head (a bound key is a hash lookup, not a table
  # scan), so keys must not contain the match-spec atoms `:_` or `:"$N"`.
  @pending :engram_cache_pending
  # Marker rows are always a miss; this expiry only lets the sweep reap the
  # marker of a loader that raised.
  @pending_ms 60_000

  # ponytail: no single-flight on miss; concurrent misses each run the loader
  # (and only the last to claim the key stores its value). Misses are rare
  # (warm node, per-user keys). Add a per-key lock if a cold key under load
  # shows up in traces.
  @spec fetch(atom(), term(), (-> term())) :: term()
  def fetch(cache, key, loader) when is_function(loader, 0) do
    case get(cache, key) do
      {:ok, value} ->
        value

      :miss ->
        token = make_ref()
        claim(cache, key, token)
        value = loader.()

        if value != nil or cache_nil?(cache),
          do: put_if_claimed(cache, key, token, value),
          else: release(cache, key, token)

        value
    end
  end

  @spec get(atom(), term()) :: {:ok, term()} | :miss
  def get(cache, key) do
    case :ets.lookup(Registry.table(cache), key) do
      [{^key, {@pending, _}, _}] -> :miss
      [{^key, value, :infinity}] -> {:ok, value}
      [{^key, value, exp}] -> if now() < exp, do: {:ok, value}, else: :miss
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @spec put(atom(), term(), term()) :: :ok
  def put(cache, key, value) do
    true = :ets.insert(Registry.table(cache), {key, value, expiry(cache)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp claim(cache, key, token) do
    true = :ets.insert(Registry.table(cache), {key, {@pending, token}, now() + @pending_ms})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp put_if_claimed(cache, key, token, value) do
    _ =
      :ets.select_replace(Registry.table(cache), [
        {{key, {@pending, token}, :_}, [], [{{{:const, key}, {:const, value}, expiry(cache)}}]}
      ])

    :ok
  rescue
    ArgumentError -> :ok
  end

  # Deletes this caller's marker only (a nil result that is not cached).
  defp release(cache, key, token) do
    _ =
      :ets.select_delete(Registry.table(cache), [
        {{key, {@pending, token}, :_}, [], [true]}
      ])

    :ok
  rescue
    ArgumentError -> :ok
  end

  # The local eviction is synchronous, so the broadcast skips this node's
  # server: echoed back, it would land later and drop a value re-cached in
  # between (a fresh read after the write's own eviction).
  @spec evict(atom(), term()) :: :ok
  def evict(cache, key) do
    :ok = evict_local(cache, key)

    CacheSync.broadcast_from(
      Process.whereis(Engram.Cache.Server),
      {:engram_cache_evict, cache, key}
    )
  end

  @spec evict_all(atom()) :: :ok
  def evict_all(cache) do
    :ok = clear_local(cache)

    CacheSync.broadcast_from(
      Process.whereis(Engram.Cache.Server),
      {:engram_cache_evict_all, cache}
    )
  end

  @spec evict_local(atom(), term()) :: :ok
  def evict_local(cache, key) do
    table = Registry.table(cache)

    _ =
      case evict_match(cache) do
        :first_elem -> :ets.match_delete(table, {{key, :_}, :_, :_})
        :key -> :ets.delete(table, key)
      end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec clear_local(atom()) :: :ok
  def clear_local(cache) do
    _ = :ets.delete_all_objects(Registry.table(cache))
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp expiry(cache) do
    case ttl(cache) do
      :infinity -> :infinity
      ms -> now() + ms
    end
  end

  defp ttl(cache), do: spec(cache, :ttl, :infinity)
  defp cache_nil?(cache), do: spec(cache, :cache_nil, false)
  defp evict_match(cache), do: spec(cache, :evict_match, :key)

  # The registry is a compile-time list of a handful of maps, so Enum.find is fine.
  defp spec(cache, field, default) do
    case Enum.find(Registry.caches(), &(&1.name == cache)) do
      nil -> default
      spec -> Map.get(spec, field, default)
    end
  end
end
