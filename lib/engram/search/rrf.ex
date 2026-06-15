defmodule Engram.Search.Rrf do
  @moduledoc """
  Reciprocal Rank Fusion for hybrid search (#595).

  Merges N ranked id-lists (the keyword leg and the vector leg) into one ranked
  list using `score(id) = Σ_legs weight_leg / (k + rank)`. Because it depends
  only on each id's *rank position* within a leg — never the raw score — the
  legs' incompatible score scales (`ts_rank_cd` vs cosine similarity) never have
  to be reconciled. The `weights` knob is the tunable blend #595 calls for.

  Note: RRF absorbs score-*scale* mismatch between legs; it does NOT fix a leg's
  internal ordering. The keyword leg is a candidate generator here, not the
  final ranker.
  """

  @default_k 60

  @type ranked :: [id :: term()]

  @doc """
  Fuse ranked id-lists. Each input list is ordered best-first (head = rank 1).
  Returns `[{id, fused_score}]` sorted by score descending, ids de-duplicated.

  Options:
    * `:k` — RRF constant (default #{@default_k}); larger `k` flattens the
      contribution of top ranks.
    * `:weights` — per-leg weights aligned with the input lists (default 1.0
      each).
  """
  @spec fuse([ranked()], keyword()) :: [{term(), float()}]
  def fuse(ranked_lists, opts \\ []) do
    k = Keyword.get(opts, :k, @default_k)
    weights = Keyword.get(opts, :weights, List.duplicate(1.0, length(ranked_lists)))

    ranked_lists
    |> Enum.zip(weights)
    |> Enum.reduce(%{}, fn {ids, weight}, acc ->
      ids
      |> Enum.with_index(1)
      |> Enum.reduce(acc, fn {id, rank}, acc ->
        contribution = weight / (k + rank)
        Map.update(acc, id, contribution, &(&1 + contribution))
      end)
    end)
    |> Enum.sort_by(fn {_id, score} -> score end, :desc)
  end
end
