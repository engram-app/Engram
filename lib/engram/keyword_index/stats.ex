defmodule Engram.KeywordIndex.Stats do
  @moduledoc """
  Per-vault `avgdl` (average chunk token length) for BM25 length normalization
  (#595). Computed from `chunks.token_count` — always reflects current vault
  state, no counter bookkeeping. Used at index time only: a note's stored
  sparse weights re-normalize to a drifted avgdl on that note's next re-encode,
  and nothing re-normalizes the rest.

  Falls back to `@default_avgdl` for an empty/new vault. 100.0 is a
  markdown-realistic bootstrap (typical chunk is 50-150 tokens); the original
  256.0 over-penalized short chunks via BM25 length-norm on a fresh vault.
  BM25 is a soft normalizer, so this value barely moves rankings once real
  chunks exist.
  """

  import Ecto.Query

  alias Engram.Cache
  alias Engram.Notes.Chunk
  alias Engram.Repo

  @default_avgdl 100.0

  @doc """
  Per-vault avgdl, cached per node (#861): every EmbedNote job reads this,
  and the uncached AVG over the vault's whole chunk set made initial
  indexing O(N^2) in DB row visits. Staleness inside the cache TTL is
  harmless. Cached in `Engram.Cache` as `:avgdl` (10 min TTL, per node).

  Takes `user_id` as well as `vault_id` because the underlying `chunks` read
  has to run inside `Repo.with_tenant/2`, and nothing in this module can derive
  the owner: the `vaults` lookup that would supply it is under the same policy.
  """
  @spec avgdl(Ecto.UUID.t(), Ecto.UUID.t()) :: float()
  def avgdl(user_id, vault_id) do
    Cache.fetch(:avgdl, vault_id, fn -> compute_avgdl(user_id, vault_id) end)
  end

  # Scoped HERE rather than around `avgdl/2` so a cache hit still costs no
  # transaction — this runs only on a miss. `chunks` carries FORCE ROW LEVEL
  # SECURITY, and unscoped the aggregate came back nil, so every vault fell
  # through to `@default_avgdl` and every BM25 weight in it was
  # length-normalized against a bootstrap constant instead of the vault's real
  # average. Nothing raised and nothing logged; the ranking just got quietly
  # worse. `Indexing.prepare_index/3`, the only caller, is documented as
  # running OUTSIDE the per-note `with_tenant/2` ("HTTP/CPU only, no DB
  # writes"), which is what left this read unscoped.
  defp compute_avgdl(user_id, vault_id) do
    Repo.with_tenant!(user_id, fn ->
      Chunk
      |> where([c], c.vault_id == ^vault_id and not is_nil(c.token_count))
      |> select([c], avg(c.token_count))
      |> Repo.one()
    end)
    |> case do
      nil -> @default_avgdl
      %Decimal{} = d -> Decimal.to_float(d)
      n when is_float(n) -> n
      n when is_integer(n) -> n * 1.0
    end
  end
end
