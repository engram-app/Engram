defmodule Engram.Search.MMRTest do
  use ExUnit.Case, async: true
  alias Engram.Search.MMR

  defp c(score, vec), do: %{score: score, vector: vec}

  test "diversity 0.0 returns the top-`limit` relevance order unchanged" do
    cands = [c(0.9, [1.0, 0.0]), c(0.8, [1.0, 0.0]), c(0.7, [0.0, 1.0])]
    assert MMR.rerank(cands, 2, 0.0) == Enum.take(cands, 2)
  end

  test "high diversity prefers a dissimilar second pick over a near-duplicate" do
    # #1 and #2 are identical direction; #3 is orthogonal but lower relevance.
    dup = c(0.80, [1.0, 0.0])
    near = c(0.79, [1.0, 0.0])
    orth = c(0.60, [0.0, 1.0])
    cands = [dup, near, orth]

    [first, second] = MMR.rerank(cands, 2, 1.0)
    assert first == dup
    # diversity beats the marginally-more-relevant near-dup
    assert second == orth
  end

  test "low diversity keeps the more-relevant near-duplicate" do
    dup = c(0.80, [1.0, 0.0])
    near = c(0.79, [1.0, 0.0])
    orth = c(0.60, [0.0, 1.0])
    [_first, second] = MMR.rerank([dup, near, orth], 2, 0.05)
    assert second == near
  end

  test "handles fewer candidates than limit" do
    cands = [c(0.9, [1.0, 0.0])]
    assert MMR.rerank(cands, 5, 1.0) == cands
  end

  test "nil vector contributes no diversity penalty (treated as similarity 0)" do
    a = c(0.9, [1.0, 0.0])
    b = c(0.8, nil)
    assert [^a, ^b] = MMR.rerank([a, b], 2, 1.0)
  end

  test "empty candidate list returns empty" do
    assert MMR.rerank([], 5, 1.0) == []
    assert MMR.rerank([], 5, 0.0) == []
  end

  # #1617: every greedy step recomputed full cosines (magnitudes included)
  # against every picked item, and `remaining -- [best]` deep-compared 1024-float
  # maps. The REST maximum (limit 50) over a ~200 pool measured 76s of CPU.
  test "a limit-50 rerank over 200 real-width vectors finishes promptly" do
    :rand.seed(:exsss, {1, 2, 3})
    cands = for i <- 1..200, do: c(1.0 - i / 1000, random_vec(1024))

    task = Task.async(fn -> MMR.rerank(cands, 50, 0.3) end)
    result = Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)

    assert {:ok, picked} = result, "MMR took longer than 5s for limit=50 over 200 candidates"
    assert length(picked) == 50
  end

  # Pins the selection order to the original O(n^3) definition, so the faster
  # version is a pure optimisation.
  test "picks the same order as the reference definition" do
    :rand.seed(:exsss, {4, 5, 6})

    for _ <- 1..25 do
      cands =
        for _ <- 1..20 do
          c(:rand.uniform(), if(:rand.uniform() < 0.1, do: nil, else: random_vec(8)))
        end

      for d <- [0.05, 0.3, 0.7, 1.0] do
        assert MMR.rerank(cands, 10, d) == reference(cands, 10, d)
      end
    end
  end

  defp random_vec(dims), do: for(_ <- 1..dims, do: :rand.uniform() - 0.5)

  defp reference(cands, limit, d) do
    scores = Enum.map(cands, & &1.score)
    {lo, hi} = Enum.min_max(scores)
    rel = fn cand -> if hi == lo, do: 1.0, else: (cand.score - lo) / (hi - lo) end

    Enum.reduce(1..min(limit, length(cands)), {cands, []}, fn _, {left, picked} ->
      best =
        Enum.max_by(left, fn cand ->
          case picked do
            [] ->
              rel.(cand)

            _ ->
              max_sim = picked |> Enum.map(&ref_cosine(cand.vector, &1.vector)) |> Enum.max()
              (1.0 - d) * rel.(cand) - d * max_sim
          end
        end)

      {List.delete(left, best), picked ++ [best]}
    end)
    |> elem(1)
  end

  defp ref_cosine(nil, _), do: 0.0
  defp ref_cosine(_, nil), do: 0.0

  defp ref_cosine(a, b) do
    dot = a |> Enum.zip(b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    na = :math.sqrt(Enum.reduce(a, 0.0, &(&1 * &1 + &2)))
    nb = :math.sqrt(Enum.reduce(b, 0.0, &(&1 * &1 + &2)))
    dot / (na * nb)
  end

  test "absent :vector key (not nil — key missing entirely) degrades safely without raising" do
    # Upstream stripping of nil vectors leaves a map with no :vector key at all.
    # Map.get/2 returns nil, which the cosine(nil, _) clause handles as 0.0
    # similarity — no KeyError, both candidates are returned.
    no_vec = %{score: 0.8}
    with_vec = %{score: 0.9, vector: [1.0, 0.0]}
    result = MMR.rerank([no_vec, with_vec], 2, 1.0)
    assert length(result) == 2
    assert with_vec in result
    assert no_vec in result
  end
end
