defmodule Engram.Onboarding.GateCache do
  @moduledoc """
  Node-local cache of the RequireOnboarding PASS verdict, keyed by user id.

  Deriving the verdict costs ~3 DB round-trips per request (profile re-read +
  `has_vault?` inside its own RLS transaction) for an answer that is true for
  essentially every post-onboarding request. Only PASS is cached — failing
  users always hit the authoritative slow path, so a stale entry can never
  withhold access, only briefly extend it.

  Staleness is bounded two ways:

    * every pass→fail transition has an eviction write-site — vault deletion
      (`Engram.Vaults.delete_vault/2`), subscription mutation (every
      `Engram.Billing.upsert_from_paddle_event/1` clause via
      `broadcast_subscription_activated/2`), profile edits
      (`Engram.Onboarding.set_profile/2`), and a terms-floor bump
      (`Engram.Legal.VersionCache.invalidate_all/0`, whose
      `:version_evict_all` broadcast this cache also consumes);
    * a #{div(60_000, 1000)}s TTL backstops any write-site this list misses.

  Cross-node: evictions ride `Engram.Cluster.CacheSync` exactly like
  `Engram.Crypto.DekCache` — the mutating node clears its own table
  synchronously, peers clear on the broadcast.
  """

  # :version_evict_all — a terms (re)seed or publish can raise the required
  # floor, flipping any passed user back to failing; drop every verdict and
  # re-derive.
  use Engram.Cache.NodeLocalEts,
    table: :engram_onboarding_gate_cache,
    cache_sync: true,
    sync_evict: :onboarding_gate_evict,
    sync_evict_all: [:version_evict_all]

  alias Engram.Cluster.CacheSync

  @ttl_ms 60_000

  @spec passed?(Ecto.UUID.t()) :: boolean()
  def passed?(user_id) do
    case ets_lookup(user_id) do
      [{^user_id, expires_at}] ->
        System.monotonic_time(:millisecond) < expires_at

      _ ->
        false
    end
  end

  @spec mark_passed(Ecto.UUID.t(), non_neg_integer()) :: :ok
  def mark_passed(user_id, ttl_ms \\ @ttl_ms) do
    ets_insert({user_id, System.monotonic_time(:millisecond) + ttl_ms})
  end

  @doc """
  Clears the verdict locally and broadcasts the eviction to peer nodes.
  Idempotent; receiving our own broadcast is a harmless double-delete.
  """
  @spec evict(Ecto.UUID.t()) :: :ok
  def evict(user_id) do
    _ = delete_local(user_id)
    CacheSync.broadcast({:onboarding_gate_evict, user_id})
  end

  @spec evict_all() :: :ok
  def evict_all do
    _ = clear_local()
    :ok
  end
end
