defmodule Engram.KeywordIndex.Stats.Cache do
  @moduledoc """
  Per-node ETS cache for per-vault avgdl (#861). Every EmbedNote job needs
  the vault's average chunk token length for BM25 length normalization;
  recomputing `SELECT avg(token_count)` per job makes initial indexing of a
  large vault O(N^2) in DB row visits. avgdl is a soft normalizer (the #605
  re-normalize worker recomputes weights when a vault drifts), so a value up
  to @ttl_ms stale is harmless — and per-node staleness is safe for the same
  reason.
  """
  use GenServer

  @table :engram_avgdl_cache
  @ttl_ms :timer.minutes(10)

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec get(binary()) :: {:ok, float()} | :miss
  def get(vault_id) do
    case :ets.lookup(@table, vault_id) do
      [{^vault_id, value, expires}] ->
        if System.monotonic_time(:millisecond) < expires, do: {:ok, value}, else: :miss

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @spec put(binary(), float()) :: :ok
  def put(vault_id, value) do
    expires = System.monotonic_time(:millisecond) + @ttl_ms
    :ets.insert(@table, {vault_id, value, expires})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec evict(binary()) :: :ok
  def evict(vault_id) do
    :ets.delete(@table, vault_id)
    :ok
  rescue
    ArgumentError -> :ok
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

    {:ok, %{}}
  end
end
