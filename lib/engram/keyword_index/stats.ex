defmodule Engram.KeywordIndex.Stats do
  @moduledoc """
  Per-vault `avgdl` (average chunk token length) for BM25 length normalization
  (#595). Computed from `chunks.token_count` — always reflects current vault
  state, no counter bookkeeping. Used at index time; the #605 re-normalize
  worker recomputes weights when a vault's avgdl drifts.

  Falls back to `@default_avgdl` for an empty/new vault. 100.0 is a
  markdown-realistic bootstrap (typical chunk is 50-150 tokens); the original
  256.0 over-penalized short chunks via BM25 length-norm on a fresh vault.
  BM25 is a soft normalizer, so this value barely moves rankings once real
  chunks exist.
  """

  import Ecto.Query

  alias Engram.KeywordIndex.Stats.Cache
  alias Engram.Notes.Chunk
  alias Engram.Repo

  @default_avgdl 100.0

  @doc """
  Per-vault avgdl, cached per node (#861): every EmbedNote job reads this,
  and the uncached AVG over the vault's whole chunk set made initial
  indexing O(N^2) in DB row visits. Staleness inside the cache TTL is
  harmless — see `Engram.KeywordIndex.Stats.Cache`.
  """
  @spec avgdl(Ecto.UUID.t()) :: float()
  def avgdl(vault_id) do
    case Cache.get(vault_id) do
      {:ok, value} ->
        value

      :miss ->
        value = compute_avgdl(vault_id)
        :ok = Cache.put(vault_id, value)
        value
    end
  end

  @doc "Drops the cached avgdl for a vault (e.g. before a bulk re-normalize)."
  @spec evict(Ecto.UUID.t()) :: :ok
  defdelegate evict(vault_id), to: Cache

  defp compute_avgdl(vault_id) do
    Chunk
    |> where([c], c.vault_id == ^vault_id and not is_nil(c.token_count))
    |> select([c], avg(c.token_count))
    |> Repo.one(skip_tenant_check: true)
    |> case do
      nil -> @default_avgdl
      %Decimal{} = d -> Decimal.to_float(d)
      n when is_float(n) -> n
      n when is_integer(n) -> n * 1.0
    end
  end
end
