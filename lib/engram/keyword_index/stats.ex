defmodule Engram.KeywordIndex.Stats do
  @moduledoc """
  Per-vault `avgdl` (average chunk token length) for BM25 length normalization
  (#595). Computed from `chunks.token_count` — always reflects current vault
  state, no counter bookkeeping. Used at index time; the #605 re-normalize
  worker recomputes weights when a vault's avgdl drifts.

  Falls back to `@default_avgdl` for an empty/new vault (matches the FastEmbed
  BM25 default). BM25 is a soft normalizer, so this bootstrap value barely
  moves rankings on small vaults.
  """

  import Ecto.Query

  alias Engram.Notes.Chunk
  alias Engram.Repo

  @default_avgdl 256.0

  @spec avgdl(Ecto.UUID.t()) :: float()
  def avgdl(vault_id) do
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
