defmodule Engram.Cluster.CacheSync do
  @moduledoc """
  Thin wrapper over `Engram.PubSub` for cross-node cache invalidation. Owns the
  single topic + message shape shared by the node-local caches that must evict
  cluster-wide when one node mutates shared state:

    * `Engram.Crypto.DekCache`     — after a DEK rotation / AAD rebind
    * `Engram.Legal.VersionCache`  — after a terms/privacy (re)seed or publish

  Pattern: the mutating node clears its OWN cache synchronously, then calls
  `broadcast/1` so peers evict. Each cache subscribes via `subscribe/0` from a
  process it owns and clears local state on its matching message. Receiving your
  own broadcast is harmless — eviction is idempotent and never re-broadcasts, so
  there is no loop.

  Message shape: `{:cache_sync, payload}` where payload is one of
  `{:dek_evict, user_id}`, `:dek_evict_all`, `:version_evict_all`. Each
  subscriber pattern-matches only its own payloads and ignores the rest.
  """

  @topic "cluster:cache_sync"

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Engram.PubSub, @topic)

  @spec broadcast(term()) :: :ok
  def broadcast(payload) do
    _ = Phoenix.PubSub.broadcast(Engram.PubSub, @topic, {:cache_sync, payload})
    :ok
  end

  @spec topic() :: String.t()
  def topic, do: @topic
end
