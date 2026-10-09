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

  # ponytail: no single-flight on miss; concurrent misses each run the loader.
  # Misses are rare (warm node, per-user keys). Add a per-key lock if a cold
  # key under load shows up in traces.
  @spec fetch(atom(), term(), (-> term())) :: term()
  def fetch(cache, key, loader) when is_function(loader, 0) do
    case get(cache, key) do
      {:ok, value} ->
        value

      :miss ->
        value = loader.()
        if value != nil or cache_nil?(cache), do: put(cache, key, value)
        value
    end
  end

  @spec get(atom(), term()) :: {:ok, term()} | :miss
  def get(cache, key) do
    case :ets.lookup(Registry.table(cache), key) do
      [{^key, value, :infinity}] -> {:ok, value}
      [{^key, value, exp}] -> if now() < exp, do: {:ok, value}, else: :miss
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @spec put(atom(), term(), term()) :: :ok
  def put(cache, key, value) do
    exp =
      case ttl(cache) do
        :infinity -> :infinity
        ms -> now() + ms
      end

    true = :ets.insert(Registry.table(cache), {key, value, exp})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec evict(atom(), term()) :: :ok
  def evict(cache, key) do
    :ok = evict_local(cache, key)
    CacheSync.broadcast({:engram_cache_evict, cache, key})
  end

  @spec evict_all(atom()) :: :ok
  def evict_all(cache) do
    :ok = clear_local(cache)
    CacheSync.broadcast({:engram_cache_evict_all, cache})
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
