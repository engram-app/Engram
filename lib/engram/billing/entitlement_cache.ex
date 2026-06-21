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

  use GenServer

  alias Engram.Cluster.CacheSync

  require Logger

  @table :engram_billing_entitlement_cache
  @ttl_ms 86_400_000
  @pg_channel "user_limit_overrides_changed"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Returns the cached entitlement map for `user_id`, or runs `fun`, caches its
  result, and returns it.
  """
  @spec fetch(Ecto.UUID.t(), (-> map())) :: map()
  def fetch(user_id, fun) do
    case lookup(user_id) do
      {:ok, value} ->
        value

      :stale ->
        value = fun.()
        put(user_id, value)
        value
    end
  end

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

  defp lookup(user_id) do
    case :ets.lookup(@table, user_id) do
      [{^user_id, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at, do: {:ok, value}, else: :stale

      _ ->
        :stale
    end
  rescue
    # Table absent (cache process down) → treat every read as stale; the
    # caller falls through to the authoritative resolution.
    ArgumentError -> :stale
  end

  defp put(user_id, value) do
    expires_at = System.monotonic_time(:millisecond) + @ttl_ms
    :ets.insert(@table, {user_id, value, expires_at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp delete_local(user_id) do
    :ets.delete(@table, user_id)
  rescue
    ArgumentError -> true
  end

  defp clear_local do
    :ets.delete_all_objects(@table)
  rescue
    ArgumentError -> true
  end

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

    :ok = CacheSync.subscribe()
    :ok = listen_pg()
    {:ok, %{}}
  end

  # LISTEN on the channel fired by the user_limit_overrides AFTER-write trigger
  # (migration 20260612100000), shared with OverrideCache. This is what makes
  # raw-SQL override writers coherent: every node hears the NOTIFY directly from
  # Postgres and evicts within milliseconds. Failure to listen is non-fatal —
  # the TTL still bounds staleness — so log and continue.
  defp listen_pg do
    case Process.whereis(Engram.PgNotifications) do
      nil ->
        Logger.warning(
          "EntitlementCache: PG notifications process not running; TTL-only eviction"
        )

      _pid ->
        {:ok, _ref} = Postgrex.Notifications.listen(Engram.PgNotifications, @pg_channel)
        :ok
    end
  catch
    kind, reason ->
      Logger.warning(
        "EntitlementCache: failed to LISTEN #{@pg_channel} (#{kind}: #{inspect(reason)}); " <>
          "TTL-only eviction"
      )
  end

  @impl true
  def handle_info({:notification, _pid, _ref, @pg_channel, user_id}, state) do
    _ = delete_local(user_id)
    {:noreply, state}
  end

  def handle_info({:cache_sync, {:billing_entitlement_evict, user_id}}, state) do
    _ = delete_local(user_id)
    {:noreply, state}
  end

  def handle_info({:cache_sync, :billing_entitlement_evict_all}, state) do
    _ = clear_local()
    {:noreply, state}
  end

  # Ignore cache_sync messages addressed to other caches.
  def handle_info({:cache_sync, _other}, state), do: {:noreply, state}
end
