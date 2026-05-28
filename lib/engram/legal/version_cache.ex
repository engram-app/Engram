defmodule Engram.Legal.VersionCache do
  @moduledoc """
  Caches the computed gate inputs (`required_floor`, `current_version`, and
  per-version `hash_for`) in :persistent_term, mirroring
  `Engram.Billing.PlanCache`. Terms versions are seeded at boot and change only
  on a publish, so per-request reads should never touch the DB. Call
  `invalidate_all/0` after seeding or a publish so the next read reloads.
  """
  alias Engram.Legal

  @spec required_floor(String.t()) :: String.t() | nil
  def required_floor(document),
    do: fetch({:floor, document}, fn -> Legal.required_floor(document) end)

  @spec current_version(String.t()) :: String.t() | nil
  def current_version(document),
    do: fetch({:current, document}, fn -> Legal.current_version(document) end)

  @spec hash_for(String.t(), String.t()) :: String.t() | nil
  def hash_for(document, version),
    do: fetch({:hash, document, version}, fn -> Legal.hash_for(document, version) end)

  @doc """
  Drop every cached entry on THIS node only (no broadcast). Used by the
  cluster Invalidator on receipt of a peer eviction and as the building block
  for `invalidate_all/0`.
  """
  @spec invalidate_local_all() :: :ok
  def invalidate_local_all do
    for {{__MODULE__, _} = k, _v} <- :persistent_term.get() do
      :persistent_term.erase(k)
    end

    :ok
  end

  @doc """
  Drop every cached entry on this node AND tell peers to do the same. Call after
  a terms/privacy (re)seed or publish so every clustered node reloads the new
  version rows from the shared DB instead of serving a stale floor/hash.
  """
  @spec invalidate_all() :: :ok
  def invalidate_all do
    :ok = invalidate_local_all()
    Engram.Cluster.CacheSync.broadcast(:version_evict_all)
  end

  defp fetch(subkey, loader) do
    key = {__MODULE__, subkey}

    case :persistent_term.get(key, :__miss__) do
      :__miss__ ->
        loaded = loader.()
        :persistent_term.put(key, loaded)
        loaded

      cached ->
        cached
    end
  end
end
