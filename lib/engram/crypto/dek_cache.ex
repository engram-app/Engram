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

  @table :engram_dek_cache
  @sweep_interval_ms :timer.minutes(5)

  ## Public API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec get(user_id :: integer()) :: {:ok, <<_::256>>} | :miss
  def get(user_id) do
    case :ets.lookup(@table, user_id) do
      [{^user_id, dek, expires_at}] ->
        if :erlang.system_time(:millisecond) < expires_at do
          {:ok, dek}
        else
          # T3.3 — eviction of an expired entry must go through the owner
          # process. Foreign processes cannot delete from a :protected ETS
          # table directly. Cast is fine: a stale entry living for one
          # extra request is harmless (decrypt under the same key).
          GenServer.cast(__MODULE__, {:expire, user_id})
          :miss
        end

      [] ->
        :miss
    end
  end

  @spec put(user_id :: integer(), dek :: <<_::256>>, ttl_ms :: non_neg_integer() | nil) :: :ok
  def put(user_id, <<_::256>> = dek, ttl_ms \\ nil) do
    ttl = ttl_ms || Application.get_env(:engram, :dek_cache_ttl_ms, 3_600_000)
    expires_at = :erlang.system_time(:millisecond) + ttl
    # GenServer.call (sync) so callers downstream can rely on the cache
    # being hot before the next read. The audit suggested cast for "writes
    # are rare," but cache-miss is paired with a network unwrap or DB
    # round-trip that already cost ms — one extra GenServer hop is noise.
    GenServer.call(__MODULE__, {:put, user_id, dek, expires_at})
  end

  @spec invalidate(user_id :: integer()) :: :ok
  def invalidate(user_id) do
    GenServer.call(__MODULE__, {:invalidate, user_id})
  end

  @spec invalidate_all() :: :ok
  def invalidate_all do
    GenServer.call(__MODULE__, :invalidate_all)
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
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])

    # T3.3 / M9 — exclude this process's heap from any BEAM crash dump.
    # The ETS table's data lives in this process's memory map, so plaintext
    # DEKs would otherwise be recoverable from `erl_crash.dump`.
    :erlang.process_flag(:sensitive, true)

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, user_id, dek, expires_at}, _from, state) do
    :ets.insert(@table, {user_id, dek, expires_at})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:invalidate, user_id}, _from, state) do
    :ets.delete(@table, user_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:invalidate_all, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    sweep()
    {:reply, :ok, state}
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

    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
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
