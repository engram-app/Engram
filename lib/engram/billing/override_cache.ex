defmodule Engram.Billing.OverrideCache do
  @moduledoc """
  Node-local read-through cache for `user_limit_overrides` lookups, keyed by
  `{user_id, limit_key}` with a #{div(60_000, 1000)}s TTL.

  `Engram.Billing.effective_limit/2` consults the override table first on
  every resolution, and hot paths resolve several limits per request (search
  checks reranker + cross_vault, the RPS/write plugs each resolve a budget).
  Overrides are rare — OG-waitlist / admin grants — so the dominant cached
  value is the MISS; both hits and misses are stored.

  Invalidation:

    * grants/revocations happen out-of-band (iex / support runbook), so the
      TTL is the primary bound — a new grant is visible within a minute;
      `evict/1` exists for callers that want immediacy.
    * `Engram.Billing.Workers.OverrideExpirySweep` calls `evict_all/0`
      whenever it deletes expired rows.
    * evictions ride `Engram.Cluster.CacheSync` so peer nodes drop their
      copies too.
  """

  use Engram.Cache.NodeLocalEts,
    table: :engram_billing_override_cache,
    ttl: 60_000,
    cache_sync: true,
    sync_evict: :billing_override_evict,
    sync_evict_all: [:billing_override_evict_all],
    pg_channel: "user_limit_overrides_changed",
    pg_log_category: :billing

  alias Engram.Cluster.CacheSync

  @doc """
  Returns the cached lookup result (`{:hit, value}` | `:miss`) for the pair,
  or runs `fun` and caches whatever it returns.
  """
  @spec fetch(Ecto.UUID.t(), String.t(), (-> {:hit, term()} | :miss)) ::
          {:hit, term()} | :miss
  def fetch(user_id, limit_key, fun), do: cache_fetch({user_id, limit_key}, fun)

  @spec evict(Ecto.UUID.t()) :: :ok
  def evict(user_id) do
    _ = delete_local(user_id)
    CacheSync.broadcast({:billing_override_evict, user_id})
  end

  @spec evict_all() :: :ok
  def evict_all do
    _ = clear_local()
    CacheSync.broadcast(:billing_override_evict_all)
  end

  # Eviction is per user while rows are keyed by {user_id, limit_key}, so the
  # macro's keyed-delete default doesn't apply: match-delete every row for the
  # user instead. Overrides the macro's defoverridable default, so the injected
  # NOTIFY / cache_sync handlers call this one.
  @doc false
  def delete_local(user_id) do
    :ets.match_delete(:engram_billing_override_cache, {{user_id, :_}, :_, :_})
  rescue
    ArgumentError -> true
  end
end
