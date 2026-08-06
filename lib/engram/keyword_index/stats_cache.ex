defmodule Engram.KeywordIndex.Stats.Cache do
  @moduledoc """
  Per-node ETS cache for per-vault avgdl (#861). Every EmbedNote job needs
  the vault's average chunk token length for BM25 length normalization;
  recomputing `SELECT avg(token_count)` per job makes initial indexing of a
  large vault O(N^2) in DB row visits. avgdl is a soft normalizer (the #605
  re-normalize worker recomputes weights when a vault drifts), so a value up
  to 10min stale is harmless — and per-node staleness is safe for the same
  reason.
  """
  use Engram.Cache.NodeLocalEts, table: :engram_avgdl_cache, ttl: :timer.minutes(10)

  @spec get(binary()) :: {:ok, float()} | :miss
  def get(vault_id) do
    case cache_lookup(vault_id) do
      {:ok, value} -> {:ok, value}
      :stale -> :miss
    end
  end

  @spec put(binary(), float()) :: :ok
  def put(vault_id, value), do: cache_put(vault_id, value)

  @spec evict(binary()) :: :ok
  def evict(vault_id) do
    _ = delete_local(vault_id)
    :ok
  end
end
