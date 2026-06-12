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

  use GenServer

  alias Engram.Cluster.CacheSync

  @table :engram_billing_override_cache
  @ttl_ms 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Returns the cached lookup result (`{:hit, value}` | `:miss`) for the pair,
  or runs `fun` and caches whatever it returns.
  """
  @spec fetch(Ecto.UUID.t(), String.t(), (-> {:hit, term()} | :miss)) ::
          {:hit, term()} | :miss
  def fetch(user_id, limit_key, fun) do
    key = {user_id, limit_key}

    case lookup(key) do
      {:ok, result} ->
        result

      :stale ->
        result = fun.()
        put(key, result)
        result
    end
  end

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

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, result, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at, do: {:ok, result}, else: :stale

      _ ->
        :stale
    end
  rescue
    # Table absent (cache process down) → treat every read as stale; the
    # caller falls through to the authoritative DB lookup.
    ArgumentError -> :stale
  end

  defp put(key, result) do
    expires_at = System.monotonic_time(:millisecond) + @ttl_ms
    :ets.insert(@table, {key, result, expires_at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp delete_local(user_id) do
    :ets.match_delete(@table, {{user_id, :_}, :_, :_})
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
    {:ok, %{}}
  end

  @impl true
  def handle_info({:cache_sync, {:billing_override_evict, user_id}}, state) do
    _ = delete_local(user_id)
    {:noreply, state}
  end

  def handle_info({:cache_sync, :billing_override_evict_all}, state) do
    _ = clear_local()
    {:noreply, state}
  end

  # Ignore cache_sync messages addressed to other caches.
  def handle_info({:cache_sync, _other}, state), do: {:noreply, state}
end
