defmodule Engram.Search.FusionTest do
  use ExUnit.Case, async: true

  alias Engram.Search.Fusion

  defp hit(id, score), do: %{id: id, score: score}
  defp ids(fused), do: Enum.map(fused, & &1.id)

  test "empty legs fuse to []" do
    assert Fusion.rrf([], 2) == []
    assert Fusion.rrf([[], []], 2) == []
  end

  test "rank 0 in both legs scores 1/2 + 1/2" do
    assert [%{id: "a", score: 1.0}] = Fusion.rrf([[hit("a", 0.9)], [hit("a", 7.0)]], 2)
  end

  test "a sparse-only rank-0 point (0.5) beats a both-leg point at ranks 3 and 3 (0.4)" do
    dense = [hit("d0", 0.9), hit("d1", 0.8), hit("d2", 0.7), hit("both", 0.6)]
    sparse = [hit("solo", 9.0), hit("s1", 8.0), hit("s2", 7.0), hit("both", 6.0)]

    fused = Fusion.rrf([dense, sparse], 2)
    by_id = Map.new(fused, &{&1.id, &1.score})

    assert by_id["solo"] == 0.5
    assert_in_delta by_id["both"], 0.4, 1.0e-12
    assert Enum.find_index(fused, &(&1.id == "solo")) < Enum.find_index(fused, &(&1.id == "both"))
  end

  test "ties break by best rank asc, then id asc, on every input order" do
    # Each point is rank 0 in one leg: all fuse to 0.5, all best rank 0.
    legs = [
      [hit("b", 0.3)],
      [hit("c", 0.9)],
      [hit("a", 0.3)]
    ]

    for _ <- 1..100 do
      assert legs |> Enum.shuffle() |> Fusion.rrf(2) |> ids() == ["a", "b", "c"]
    end
  end

  # Dense scores are cosine (<= 1), sparse are BM25 (2 to 20). A tie-break on
  # raw scores handed every cross-leg tie to the keyword point, the top
  # result included. Rank is the one scale both legs share.
  test "a dense rank-0 vs sparse rank-0 tie ignores the raw scores" do
    dense = [hit("sem-best", 0.82), hit("d2", 0.80)]
    sparse = [hit("kw-best", 7.4), hit("s2", 6.0)]
    rescaled = Enum.map(sparse, &%{&1 | score: &1.score / 1000})

    expected = ["kw-best", "sem-best", "d2", "s2"]
    assert ids(Fusion.rrf([dense, sparse], 2)) == expected
    assert ids(Fusion.rrf([dense, rescaled], 2)) == expected
    assert ids(Fusion.rrf([sparse, dense], 2)) == expected
  end

  test "both-leg points: equal fused and best rank fall to id; a better best rank wins first" do
    # x: dense 0 + sparse 1; y: dense 1 + sparse 0. Same fused, same best rank.
    dense = [hit("x", 0.5), hit("y", 0.4)]
    sparse = [hit("y", 3.0), hit("x", 2.0)]

    for _ <- 1..100 do
      assert [dense, sparse] |> Enum.shuffle() |> Fusion.rrf(2) |> ids() == ["x", "y"]
    end

    # zz: dense 0 + sparse 4 (1/2 + 1/6); aa: dense 1 + sparse 1 (1/3 + 1/3).
    # Both fuse to 2/3; zz's best rank is 0, aa's is 1, so zz wins over the
    # smaller id.
    dense = [hit("zz", 0.9), hit("aa", 0.8)]
    sparse = [hit("s0", 9.0), hit("aa", 8.0), hit("s2", 7.0), hit("s3", 6.0), hit("zz", 5.0)]
    fused = Fusion.rrf([dense, sparse], 2)
    by_id = Map.new(fused, &{&1.id, &1.score})

    assert by_id["zz"] == by_id["aa"]
    assert Enum.take(ids(fused), 2) == ["zz", "aa"]
  end

  test "keeps the first leg's map for a point, with the fused score" do
    dense = [%{id: "a", score: 0.9, vector: [0.1]}]
    sparse = [%{id: "a", score: 4.0}]
    assert [%{id: "a", score: 1.0, vector: [0.1]}] = Fusion.rrf([dense, sparse], 2)
  end
end
