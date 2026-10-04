defmodule Engram.Search.MMR do
  @moduledoc """
  Maximal Marginal Relevance reselection.

  Greedily picks `limit` candidates from a relevance-sorted pool, each step
  maximising `(1 - d) * rel - d * max_sim_to_already_picked`, where `rel` is the
  candidate's relevance score normalised to [0,1] within the pool and `sim` is
  cosine similarity between dense vectors. `d` (diversity) ∈ [0,1].

  `d == 0.0` short-circuits to the relevance order (no vectors required).

  The selection runs in Rust (`Engram.Native.mmr_select/4`, #1798): O(pool ×
  limit) dot products over unit vectors, each candidate carrying its running
  max similarity to the picked set (#1617). In Elixir every multiply-add
  allocated a boxed float, ~2.5 s for a limit-50 rerank over a 200 × 1024
  pool. A nil or zero vector has no direction: similarity 0.0, no penalty.
  Ties resolve in pool order.
  """

  @spec rerank([map()], pos_integer(), float()) :: [map()]
  def rerank(candidates, limit, diversity)

  def rerank(candidates, limit, diversity) when diversity == 0.0,
    do: Enum.take(candidates, limit)

  def rerank(_candidates, limit, _diversity) when limit <= 0, do: []

  def rerank(candidates, limit, diversity)
      when is_list(candidates) and is_number(diversity) do
    pool = List.to_tuple(candidates)

    candidates
    |> Enum.map(&Map.get(&1, :vector))
    |> Engram.Native.mmr_select(Enum.map(candidates, & &1.score), limit, diversity)
    |> Enum.map(&elem(pool, &1))
  end
end
