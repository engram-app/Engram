defmodule Engram.Search.MMR do
  @moduledoc """
  Maximal Marginal Relevance reselection.

  Greedily picks `limit` candidates from a relevance-sorted pool, each step
  maximising `(1 - d) * rel - d * max_sim_to_already_picked`, where `rel` is the
  candidate's relevance score normalised to [0,1] within the pool and `sim` is
  cosine similarity between dense vectors. `d` (diversity) ∈ [0,1].

  `d == 0.0` short-circuits to the relevance order (no vectors required).
  """

  @spec rerank([map()], pos_integer(), float()) :: [map()]
  def rerank(candidates, limit, diversity)

  def rerank(candidates, limit, diversity) when diversity == 0.0,
    do: Enum.take(candidates, limit)

  def rerank(candidates, limit, diversity)
      when is_list(candidates) and is_number(diversity) do
    normed = normalize_relevance(candidates)

    select(normed, [], min(limit, length(normed)), diversity)
    |> Enum.reverse()
    |> Enum.map(& &1.candidate)
  end

  # ── greedy selection ──────────────────────────────────────────────

  defp select(_remaining, acc, 0, _d), do: acc
  defp select([], acc, _n, _d), do: acc

  defp select(remaining, acc, n, d) do
    best =
      Enum.max_by(remaining, fn item ->
        mmr_score(item, acc, d)
      end)

    select(remaining -- [best], [best | acc], n - 1, d)
  end

  defp mmr_score(item, [], _d), do: item.rel

  defp mmr_score(item, selected, d) do
    max_sim =
      selected
      |> Enum.map(fn s -> cosine(item.candidate.vector, s.candidate.vector) end)
      |> Enum.max(fn -> 0.0 end)

    (1.0 - d) * item.rel - d * max_sim
  end

  # ── helpers ───────────────────────────────────────────────────────

  defp normalize_relevance(candidates) do
    scores = Enum.map(candidates, & &1.score)
    {min_s, max_s} = {Enum.min(scores, fn -> 0.0 end), Enum.max(scores, fn -> 0.0 end)}
    range = max_s - min_s

    Enum.map(candidates, fn cand ->
      rel = if range == 0.0, do: 1.0, else: (cand.score - min_s) / range
      %{candidate: cand, rel: rel}
    end)
  end

  # Cosine similarity in [-1,1]; nil vectors → 0.0 (no penalty).
  defp cosine(nil, _), do: 0.0
  defp cosine(_, nil), do: 0.0

  defp cosine(a, b) when is_list(a) and is_list(b) do
    dot = a |> Enum.zip(b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    mag_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    mag_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))
    if mag_a == 0.0 or mag_b == 0.0, do: 0.0, else: dot / (mag_a * mag_b)
  end
end
