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

  test "ties break by max leg score desc, then id asc, on every input order" do
    # Each point is rank 0 in one leg: all fuse to 0.5.
    legs = [
      [hit("b", 0.3)],
      [hit("c", 0.9)],
      [hit("a", 0.3)]
    ]

    expected = ["c", "a", "b"]

    for _ <- 1..100 do
      assert legs |> Enum.shuffle() |> Fusion.rrf(2) |> ids() == expected
    end
  end

  test "tied fused scores across two legs give one order on 100 shuffles" do
    dense = [hit("x", 0.5), hit("y", 0.4)]
    sparse = [hit("y", 3.0), hit("x", 2.0)]
    first = ids(Fusion.rrf([dense, sparse], 2))

    for _ <- 1..100 do
      assert [dense, sparse] |> Enum.shuffle() |> Fusion.rrf(2) |> ids() == first
    end

    # Equal fused (1/2 + 1/3 each); y holds the larger leg score.
    assert first == ["y", "x"]
  end

  test "keeps the first leg's map for a point, with the fused score" do
    dense = [%{id: "a", score: 0.9, vector: [0.1]}]
    sparse = [%{id: "a", score: 4.0}]
    assert [%{id: "a", score: 1.0, vector: [0.1]}] = Fusion.rrf([dense, sparse], 2)
  end
end
