defmodule Engram.Search.MMR do
  @moduledoc """
  Maximal Marginal Relevance reselection.

  Greedily picks `limit` candidates from a relevance-sorted pool, each step
  maximising `(1 - d) * rel - d * max_sim_to_already_picked`, where `rel` is the
  candidate's relevance score normalised to [0,1] within the pool and `sim` is
  cosine similarity between dense vectors. `d` (diversity) ∈ [0,1].

  `d == 0.0` short-circuits to the relevance order (no vectors required).

  Cost is O(pool × limit) dot products (#1617). Vectors are normalised once so
  a cosine is a plain dot product, and each candidate carries its running max
  similarity to the picked set, so a step compares against the newest pick
  only. The previous version recomputed full cosines against every pick on
  every step and deep-compared 1024-float maps to drop the pick: 76s of CPU
  for one limit-50 request over a ~200 pool.
  """

  @spec rerank([map()], pos_integer(), float()) :: [map()]
  def rerank(candidates, limit, diversity)

  def rerank(candidates, limit, diversity) when diversity == 0.0,
    do: Enum.take(candidates, limit)

  def rerank(candidates, limit, diversity)
      when is_list(candidates) and is_number(diversity) do
    normed = prepare(candidates)

    select(normed, [], min(limit, length(normed)), diversity)
    |> Enum.reverse()
    |> Enum.map(& &1.candidate)
  end

  # ── greedy selection ──────────────────────────────────────────────

  defp select(_remaining, acc, 0, _d), do: acc
  defp select([], acc, _n, _d), do: acc

  defp select(remaining, acc, n, d) do
    # `max_by` keeps the FIRST maximum, so ties still resolve in pool order.
    {best, best_idx} =
      remaining
      |> Enum.with_index()
      |> Enum.max_by(fn {item, _idx} -> mmr_score(item, acc, d) end)

    rest =
      for {item, idx} <- Enum.with_index(remaining), idx != best_idx do
        %{item | max_sim: running_max(item.max_sim, dot(item.unit, best.unit))}
      end

    select(rest, [best | acc], n - 1, d)
  end

  defp mmr_score(item, [], _d), do: item.rel
  defp mmr_score(item, _selected, d), do: (1.0 - d) * item.rel - d * item.max_sim

  defp running_max(nil, sim), do: sim
  defp running_max(prev, sim), do: max(prev, sim)

  # ── helpers ───────────────────────────────────────────────────────

  defp prepare(candidates) do
    scores = Enum.map(candidates, & &1.score)
    {min_s, max_s} = {Enum.min(scores, fn -> 0.0 end), Enum.max(scores, fn -> 0.0 end)}
    range = max_s - min_s

    Enum.map(candidates, fn cand ->
      rel = if range == 0.0, do: 1.0, else: (cand.score - min_s) / range
      %{candidate: cand, rel: rel, unit: unit(Map.get(cand, :vector)), max_sim: nil}
    end)
  end

  # A nil or zero vector has no direction: similarity 0.0 (no penalty).
  defp unit(nil), do: nil

  defp unit(v) when is_list(v) do
    mag = :math.sqrt(Enum.reduce(v, 0.0, fn x, acc -> acc + x * x end))
    if mag == 0.0, do: nil, else: Enum.map(v, &(&1 / mag))
  end

  defp dot(nil, _), do: 0.0
  defp dot(_, nil), do: 0.0
  defp dot(a, b), do: Enum.zip_reduce(a, b, 0.0, fn x, y, acc -> acc + x * y end)
end
