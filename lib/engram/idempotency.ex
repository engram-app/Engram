defmodule Engram.Idempotency do
  @moduledoc """
  ETS-backed idempotency-key cache for batch endpoints.
  TTL default 24h; entries beyond TTL return :miss.

  A periodic sweep deletes expired rows — entries cache full response
  bodies, and lazy expiry alone (lookup returning :miss) never reclaimed
  the memory.
  """
  use GenServer

  @table :engram_idempotency
  @default_ttl_ms 24 * 60 * 60 * 1000
  @sweep_interval_ms 10 * 60 * 1000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    _ = :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    _ = schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    # Matches {key, response, expires_at} where expires_at <= now.
    _ = :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    _ = schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  def remember(key, response, opts \\ []) do
    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    expires_at = System.monotonic_time(:millisecond) + ttl
    :ets.insert(@table, {key, response, expires_at})
    :ok
  end

  def lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, response, expires_at}] ->
        if expires_at > System.monotonic_time(:millisecond),
          do: {:ok, response},
          else: :miss

      [] ->
        :miss
    end
  end
end
