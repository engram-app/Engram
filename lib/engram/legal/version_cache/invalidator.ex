defmodule Engram.Legal.VersionCache.Invalidator do
  @moduledoc """
  Subscribes to `Engram.Cluster.CacheSync` and clears this node's
  `Engram.Legal.VersionCache` when a peer publishes/reseeds terms. `VersionCache`
  is a pure `:persistent_term` module with no process of its own, so this thin
  GenServer owns the subscription and the local-clear callback.
  """
  use GenServer
  alias Engram.Legal.VersionCache

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    _ = Engram.Cluster.CacheSync.subscribe()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:cache_sync, :version_evict_all}, state) do
    VersionCache.invalidate_local_all()
    {:noreply, state}
  end

  # Ignore cache_sync messages addressed to other caches.
  @impl true
  def handle_info({:cache_sync, _other}, state), do: {:noreply, state}
end
