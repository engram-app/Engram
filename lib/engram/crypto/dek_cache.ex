defmodule Engram.Crypto.DekCache do
  @moduledoc """
  ETS-backed cache for unwrapped DEKs. TTL-based expiry; sweep GenServer
  evicts expired entries periodically. On node shutdown, all DEKs vanish
  (correct — they re-populate on next request via KMS/Local unwrap).
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
          :ets.delete(@table, user_id)
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
    :ets.insert(@table, {user_id, dek, expires_at})
    :ok
  end

  @spec invalidate(user_id :: integer()) :: :ok
  def invalidate(user_id) do
    :ets.delete(@table, user_id)
    :ok
  end

  @spec invalidate_all() :: :ok
  def invalidate_all do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Force an immediate sweep; exposed for tests."
  def sweep_now, do: GenServer.call(__MODULE__, :sweep)

  ## GenServer

  @impl true
  def init(:ok) do
    # :public is required because get/put/invalidate are called directly by
    # caller processes (Notes, Oban workers) without routing through this
    # GenServer — avoids serialization bottleneck on hot path. Trade-off:
    # any BEAM process can read wrapped DEKs from the table. Acceptable
    # because plaintext DEKs never persist to disk and are cleared on
    # node restart. If tightening to :protected, move get/put/invalidate
    # into GenServer.call/cast.
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    sweep()
    {:reply, :ok, state}
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
