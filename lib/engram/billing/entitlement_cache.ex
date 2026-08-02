defmodule Engram.Billing.EntitlementCache do
  @moduledoc """
  Node-local read-through cache of a user's resolved *entitlements* — their
  tier plus the full `Engram.Billing.LimitKeys` matrix — keyed by user id.

  `Engram.Billing.capabilities/1` resolves every `LimitKeys` key for a user
  (each a `effective_limit/2` walk over override → env → plan → default). That
  answer is stable for the life of a subscription, so the bootstrap path
  (`GET /api/bootstrap`) and any future hot caller can serve it from a single
  ETS read instead of re-resolving the whole matrix per request.

  Unlike `OverrideCache` (which caches the raw override row lookup, hits AND
  misses, on a 60s TTL), this caches the *fully resolved* capability map on a
  long #{div(86_400_000, 3_600_000)}h TTL — because freshness here is carried by
  explicit invalidation, not by the TTL:

    * subscription mutations (created/updated/canceled) evict via
      `Engram.Billing.broadcast_subscription_activated/2` — tier flips change
      every limit, so the cached map must re-derive;
    * override expiry (`Engram.Billing.Workers.OverrideExpirySweep`) calls
      `evict_all/0` whenever it deletes rows;
    * out-of-band override writes (support runbook / e2e SQL) fire the
      `user_limit_overrides_changed` Postgres NOTIFY — this cache LISTENs on it
      exactly like `OverrideCache`, so a grant/revoke evicts the affected user
      on every node within milliseconds.

  The long TTL is purely a backstop for an invalidation site this list misses;
  it is NOT the freshness mechanism. A stale entry can only ever extend an
  entitlement for at most the TTL — server-side enforcement
  (`check_limit/3` / `check_feature/2`) remains the authoritative gate, so this
  cache is advisory for UX, never a security boundary.

  Cross-node evictions ride `Engram.Cluster.CacheSync` like every other
  node-local cache here.
  """

  use Engram.Cache.NodeLocalEts,
    table: :engram_billing_entitlement_cache,
    ttl: 86_400_000,
    cache_sync: true,
    sync_evict: :billing_entitlement_evict,
    sync_evict_all: [:billing_entitlement_evict_all],
    pg_channel: "user_limit_overrides_changed",
    pg_log_category: :billing

  alias Engram.Cluster.CacheSync

  @doc """
  Returns the cached entitlement map for `user_id`, or runs `fun`, caches its
  result, and returns it.
  """
  @spec fetch(Ecto.UUID.t(), (-> map())) :: map()
  def fetch(user_id, fun), do: cache_fetch(user_id, fun)

  @doc """
  Clears the entitlement entry for one user locally and on peer nodes. Call on
  every entitlement-changing event (subscription mutation, override write).
  """
  @spec evict(Ecto.UUID.t()) :: :ok
  def evict(user_id) do
    _ = delete_local(user_id)
    CacheSync.broadcast({:billing_entitlement_evict, user_id})
  end

  @doc "Flushes every entry locally and on peer nodes (bulk override expiry)."
  @spec evict_all() :: :ok
  def evict_all do
    _ = clear_local()
    CacheSync.broadcast(:billing_entitlement_evict_all)
  end
end
