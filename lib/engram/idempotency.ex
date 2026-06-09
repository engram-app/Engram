defmodule Engram.Idempotency do
  @moduledoc """
  ETS-backed idempotency-key cache for batch endpoints.
  TTL default 24h; entries beyond TTL return :miss.
  """
  use GenServer

  @table :engram_idempotency
  @default_ttl_ms 24 * 60 * 60 * 1000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
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
