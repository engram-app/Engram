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
end
