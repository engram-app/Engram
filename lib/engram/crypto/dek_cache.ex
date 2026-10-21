defmodule Engram.Crypto.DekCache do
  @moduledoc """
  ETS-backed cache for unwrapped DEKs. TTL-based expiry; sweep GenServer
  evicts expired entries periodically. On node shutdown, all DEKs vanish
  (correct — they re-populate on next request via KMS/Local unwrap).

  ## Security posture (T3.3 / H2 + M9)

  Reads go directly through ETS for `read_concurrency: true` performance.
  Writes (`put/3`, `invalidate/1`, `invalidate_all/0`, sweep) all flow
  through this GenServer because the table is `:protected` — only the
  owning process can mutate it. Any foreign-process `:ets.insert/2` or
  `:ets.delete/2` raises `ArgumentError`. Pre-T3.3 the table was `:public`,
  exposing every cached plaintext DEK to a poison-replace attack from any
  in-process actor (LiveDashboard, remote IEx, future deps).

  The owner GenServer also sets `:erlang.process_flag(:sensitive, true)`
  so its heap (which holds plaintext DEKs in the ETS table backing
  storage) is excluded from any future BEAM crash dump.
  """

  use GenServer

  alias Engram.Cluster.CacheSync

  @table :engram_dek_cache
  @pending :engram_dek_pending
  # A claim reads as a miss to `get/1`; this expiry only lets the sweep reap
  # the claim of a loader that crashed.
  @pending_ms 60_000
  # How long `claim_or_await/1` waits on another loader before claiming over
  # it (`:dek_await_ms`). Bounds a caller behind a stalled KMS call (ExAws
  # retries with backoff).
  @await_ms 15_000
  @sweep_interval_ms :timer.minutes(5)

  ## Public API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec get(user_id :: String.t()) :: {:ok, <<_::256>>} | :miss
  def get(user_id) do
    case :ets.lookup(@table, user_id) do
      [{^user_id, {@pending, _token}, _}] ->
        emit_lookup(:miss)
        :miss

      [{^user_id, dek, expires_at}] ->
        if :erlang.system_time(:millisecond) < expires_at do
          emit_lookup(:hit)
          {:ok, dek}
        else
          # T3.3 — eviction of an expired entry must go through the owner
          # process. Foreign processes cannot delete from a :protected ETS
          # table directly. Cast is fine: a stale entry living for one
          # extra request is harmless (decrypt under the same key).
          GenServer.cast(__MODULE__, {:expire, user_id})
          emit_lookup(:miss)
          :miss
        end

      [] ->
        emit_lookup(:miss)
        :miss
    end
  end

  # A miss is paired with a provider unwrap (Local ~µs, AWS KMS a network
  # RPC), so the hit/miss ratio is the cheapest leading indicator of
  # read-path crypto cost.
  defp emit_lookup(outcome) do
    :telemetry.execute([:engram, :crypto, :dek_cache], %{count: 1}, %{outcome: outcome})
  end

  @spec put(user_id :: String.t(), dek :: <<_::256>>, ttl_ms :: non_neg_integer() | nil) :: :ok
  def put(user_id, <<_::256>> = dek, ttl_ms \\ nil) do
    ttl = ttl_ms || Application.get_env(:engram, :dek_cache_ttl_ms, 3_600_000)
    expires_at = :erlang.system_time(:millisecond) + ttl
    # GenServer.call (sync) so callers downstream can rely on the cache
    # being hot before the next read. The audit suggested cast for "writes
    # are rare," but cache-miss is paired with a network unwrap or DB
    # round-trip that already cost ms — one extra GenServer hop is noise.
    GenServer.call(__MODULE__, {:put, user_id, dek, expires_at})
  end

  @doc """
  Claims `user_id`'s slot before a miss loads the DEK (`Crypto.get_dek/1`).
  The slot reads as a miss until `put_if_claimed/3`. Any invalidate, local or
  a peer's `dek_evict`, deletes the claim, so a DEK unwrapped from a blob read
  before a rotation's flip is never stored over it. The returned token
  identifies this claim; a later claim replaces it. The caller is monitored
  as the claim's loader (see `claim_or_await/1`).
  """
  @spec claim(user_id :: String.t()) :: reference()
  def claim(user_id), do: GenServer.call(__MODULE__, {:claim, user_id})

  @doc """
  Single-flight entry for a `get/1` miss. Returns the cached DEK, claims a free
  slot for the caller to load (`{:claimed, token}`), or, while another loader
  holds the claim, waits for that loader's DEK. Without the wait every
  concurrent miss unwrapped on its own: one KMS Decrypt per caller.

  `{:error, reason}` is the loader's own failure, handed to every waiter so a
  failing KMS costs one call per burst, not one per caller. `:retry` means the
  claim ended without a DEK or an error (loader died, or an invalidate
  landed) and the caller should ask again. Loaders are monitored, so a
  crashed loader wakes its waiters instead of leaving them on the claim until
  it expires. A loader asking again for its own claim claims over rather
  than wait on itself.
  """
  @spec claim_or_await(user_id :: String.t()) ::
          {:ok, <<_::256>>} | {:claimed, reference()} | {:error, term()} | :retry
  def claim_or_await(user_id) do
    await_ms = Application.get_env(:engram, :dek_await_ms, @await_ms)
    GenServer.call(__MODULE__, {:claim_or_await, user_id}, await_ms)
  catch
    # A loader stuck past the await budget: claim over it (monitored) rather
    # than hang. Its late put_if_claimed then reads :stale.
    :exit, {:timeout, _} -> {:claimed, claim(user_id)}
  end

  @doc """
  Drops `token`'s claim after a failed load, failing its waiters with
  `{:error, reason}`. A no-op if the claim was already replaced or
  invalidated: the waiters then belong to whoever holds the slot now.
  """
  @spec release(user_id :: String.t(), token :: reference(), reason :: term()) :: :ok
  def release(user_id, token, reason),
    do: GenServer.call(__MODULE__, {:release, user_id, token, reason})

  @doc """
  Stores `dek` only if `token`'s claim is still in the slot. `:stale` means an
  invalidate (or a newer claim) landed meanwhile: the caller may use the DEK
  it loaded for its own operation, but it is not cached. Provisioning
  (`ensure_user_dek/1`) has no race and keeps the unconditional `put/3`.
  """
  @spec put_if_claimed(String.t(), reference(), <<_::256>>, non_neg_integer() | nil) ::
          :ok | :stale
  def put_if_claimed(user_id, token, <<_::256>> = dek, ttl_ms \\ nil) do
    ttl = ttl_ms || Application.get_env(:engram, :dek_cache_ttl_ms, 3_600_000)
    expires_at = :erlang.system_time(:millisecond) + ttl
    GenServer.call(__MODULE__, {:put_if_claimed, user_id, token, dek, expires_at})
  end

  @spec invalidate(user_id :: String.t()) :: :ok
  def invalidate(user_id) do
    :ok = GenServer.call(__MODULE__, {:invalidate, user_id})
    CacheSync.broadcast({:dek_evict, user_id})
  end

  @doc "Removes the cached DEK for `user_id`, if any. Alias of `invalidate/1`."
  @spec delete(user_id :: String.t()) :: :ok
  def delete(user_id), do: invalidate(user_id)

  @spec invalidate_all() :: :ok
  def invalidate_all do
    :ok = GenServer.call(__MODULE__, :invalidate_all)
    CacheSync.broadcast(:dek_evict_all)
  end

  @doc "Force an immediate sweep; exposed for tests."
  def sweep_now, do: GenServer.call(__MODULE__, :sweep)

  @doc false
  # T3.3 / M9 — test helper only. `process_info(pid, :sensitive)` is not
  # a valid introspection key on current OTP, so we round-trip through
  # the owner: `process_flag/2` returns the previous value, so toggling
  # true→true is a non-mutating read.
  @spec sensitive_flag?() :: boolean()
  def sensitive_flag?, do: GenServer.call(__MODULE__, :__sensitive_flag__)

  ## GenServer

  @impl true
  def init(:ok) do
    # T3.3 / H2 — `:protected` means only this process can mutate the
    # table. Foreign reads still work (set: true is the default). The
    # `read_concurrency: true` flag keeps direct-ETS reads cheap from
    # any caller process.
    _ = :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])

    # T3.3 / M9 — exclude this process's heap from any BEAM crash dump.
    # The ETS table's data lives in this process's memory map, so plaintext
    # DEKs would otherwise be recoverable from `erl_crash.dump`.
    _ = :erlang.process_flag(:sensitive, true)

    # Cross-node eviction: peers broadcast here after a DEK rotation / rebind so
    # this node drops its now-unwrappable cached DEK instead of serving it for
    # up to the TTL. See Engram.Cluster.CacheSync.
    _ = CacheSync.subscribe()

    schedule_sweep()
    # waiters: user_id => callers parked on that user's claim.
    # loaders: monitor ref => {user_id, token, pid} of each claim's holder.
    {:ok, %{waiters: %{}, loaders: %{}}}
  end

  @impl true
  def handle_call({:put, user_id, dek, expires_at}, _from, state) do
    :ets.insert(@table, {user_id, dek, expires_at})
    {:reply, :ok, settle(state, user_id)}
  end

  @impl true
  def handle_call({:claim, user_id}, {pid, _}, state) do
    {token, state} = new_claim(state, user_id, pid)
    {:reply, token, state}
  end

  @impl true
  def handle_call({:claim_or_await, user_id}, {pid, _} = from, state) do
    now = :erlang.system_time(:millisecond)

    case :ets.lookup(@table, user_id) do
      [{^user_id, {@pending, token}, expires_at}] when now < expires_at ->
        if loader?(state, user_id, token, pid) do
          {token, state} = new_claim(state, user_id, pid)
          {:reply, {:claimed, token}, state}
        else
          {:noreply, %{state | waiters: Map.update(state.waiters, user_id, [from], &[from | &1])}}
        end

      [{^user_id, dek, expires_at}] when is_binary(dek) and now < expires_at ->
        # Filled between the caller's get/1 miss and this call: an unwrap
        # saved, same as a served waiter.
        emit_lookup(:coalesced)
        {:reply, {:ok, dek}, state}

      _ ->
        {token, state} = new_claim(state, user_id, pid)
        {:reply, {:claimed, token}, state}
    end
  end

  @impl true
  def handle_call({:release, user_id, token, reason}, _from, state) do
    case :ets.lookup(@table, user_id) do
      [{^user_id, {@pending, ^token}, _}] ->
        :ets.delete(@table, user_id)
        {:reply, :ok, settle(state, user_id, {:error, reason})}

      _ ->
        {:reply, :ok, settle(state, user_id)}
    end
  end

  @impl true
  def handle_call({:put_if_claimed, user_id, token, dek, expires_at}, _from, state) do
    # Check-and-insert in the owner, which serializes it against every
    # invalidate (calls and peer dek_evict messages alike).
    case :ets.lookup(@table, user_id) do
      [{^user_id, {@pending, ^token}, _}] ->
        :ets.insert(@table, {user_id, dek, expires_at})
        {:reply, :ok, settle(state, user_id)}

      _ ->
        {:reply, :stale, state}
    end
  end

  @impl true
  def handle_call({:invalidate, user_id}, _from, state) do
    :ets.delete(@table, user_id)
    {:reply, :ok, settle(state, user_id)}
  end

  @impl true
  def handle_call(:invalidate_all, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, settle_all(state)}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    sweep()
    {:reply, :ok, settle_all(state)}
  end

  @impl true
  def handle_call(:__sensitive_flag__, _from, state) do
    # process_flag/2 returns previous value; toggling true→true reads
    # without mutating.
    was = :erlang.process_flag(:sensitive, true)
    {:reply, was, state}
  end

  @impl true
  def handle_cast({:expire, user_id}, state) do
    # Re-check expiry under the owner — another caller may have already
    # refreshed the entry. Only delete if still expired.
    case :ets.lookup(@table, user_id) do
      [{^user_id, _dek, expires_at}] ->
        if :erlang.system_time(:millisecond) >= expires_at do
          :ets.delete(@table, user_id)
        end

      [] ->
        :ok
    end

    {:noreply, settle(state, user_id)}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, settle_all(state)}
  end

  @impl true
  def handle_info({:cache_sync, {:dek_evict, user_id}}, state) do
    :ets.delete(@table, user_id)
    {:noreply, settle(state, user_id)}
  end

  @impl true
  def handle_info({:cache_sync, :dek_evict_all}, state) do
    :ets.delete_all_objects(@table)
    {:noreply, settle_all(state)}
  end

  # A loader died holding its claim: drop the claim so waiters retry now
  # instead of waiting out @pending_ms.
  @impl true
  def handle_info({:DOWN, mref, :process, _pid, _reason}, state) do
    case Map.pop(state.loaders, mref) do
      {{user_id, token, _pid}, loaders} ->
        :ets.match_delete(@table, {user_id, {@pending, token}, :_})
        {:noreply, settle(%{state | loaders: loaders}, user_id)}

      {nil, _} ->
        {:noreply, state}
    end
  end

  # Ignore cache_sync messages addressed to other caches.
  @impl true
  def handle_info({:cache_sync, _other}, state), do: {:noreply, state}

  defp new_claim(state, user_id, pid) do
    token = make_ref()
    expires_at = :erlang.system_time(:millisecond) + @pending_ms
    :ets.insert(@table, {user_id, {@pending, token}, expires_at})
    state = settle(state, user_id)
    {token, put_in(state.loaders[Process.monitor(pid)], {user_id, token, pid})}
  end

  defp loader?(state, user_id, token, pid),
    do: Enum.any?(state.loaders, fn {_, loader} -> loader == {user_id, token, pid} end)

  # Reconciles waiters and loaders with `user_id`'s slot after any mutation.
  # Slot holds a DEK: serve every waiter. Slot empty: wake them with `empty`
  # (`:retry`, or the releasing loader's error). Slot still claimed: waiters
  # keep waiting on whoever holds it now. Loaders whose claim is no longer
  # the one in the slot are demonitored either way.
  defp settle(state, user_id, empty \\ :retry) do
    current =
      case :ets.lookup(@table, user_id) do
        [{^user_id, {@pending, token}, _}] -> {:pending, token}
        [{^user_id, dek, _}] -> {:ok, dek}
        [] -> empty
      end

    {done, loaders} =
      Map.split_with(state.loaders, fn {_mref, {uid, token, _pid}} ->
        uid == user_id and current != {:pending, token}
      end)

    Enum.each(done, fn {mref, _} -> Process.demonitor(mref, [:flush]) end)
    state = %{state | loaders: loaders}

    case current do
      {:pending, _} ->
        state

      reply ->
        {waiters, rest} = Map.pop(state.waiters, user_id, [])

        Enum.each(waiters, fn from ->
          GenServer.reply(from, reply)
          if match?({:ok, _}, reply), do: emit_lookup(:coalesced)
        end)

        %{state | waiters: rest}
    end
  end

  defp settle_all(state) do
    user_ids = Map.keys(state.waiters) ++ Enum.map(state.loaders, fn {_, {uid, _, _}} -> uid end)
    user_ids |> Enum.uniq() |> Enum.reduce(state, &settle(&2, &1))
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp sweep do
    now = :erlang.system_time(:millisecond)

    :ets.foldl(
      fn {user_id, _dek, expires_at}, _acc ->
        if now >= expires_at, do: :ets.delete(@table, user_id)
        nil
      end,
      nil,
      @table
    )
  end
end
