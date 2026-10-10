defmodule Engram.Billing.OverrideCache do
  @moduledoc """
  Read-through cache for `user_limit_overrides` lookups, keyed by
  `{user_id, limit_key}` (`:billing_override` in `Engram.Cache.Registry`,
  60s TTL).

  `Engram.Billing.effective_limit/2` consults the override table first on
  every resolution, and hot paths resolve several limits per request (search
  checks reranker + cross_vault, the RPS/write plugs each resolve a budget).
  Overrides are rare — OG-waitlist / admin grants — so the dominant cached
  value is the MISS; both hits and misses are stored.

  Invalidation:

    * the `user_limit_overrides_changed` Postgres NOTIFY (AFTER-write trigger)
      evicts the user on every node, so raw-SQL grants are covered;
      `evict/1` exists for callers that want immediacy.
    * `Engram.Billing.Workers.OverrideExpirySweep` calls `evict_all/0`
      whenever it deletes expired rows.
    * evictions ride `Engram.Cluster.CacheSync` so peer nodes drop their
      copies too.
  """

  alias Engram.Cache

  @doc """
  Returns the cached lookup result (`{:hit, value}` | `:miss`) for the pair,
  or runs `fun` and caches whatever it returns.
  """
  @spec fetch(Ecto.UUID.t(), String.t(), (-> {:hit, term()} | :miss)) ::
          {:hit, term()} | :miss
  def fetch(user_id, limit_key, fun),
    do: Cache.fetch(:billing_override, {user_id, limit_key}, fun)

  @spec evict(Ecto.UUID.t()) :: :ok
  def evict(user_id), do: Cache.evict(:billing_override, user_id)

  @spec evict_all() :: :ok
  def evict_all, do: Cache.evict_all(:billing_override)
end
