defmodule Engram.Search.RrfTest do
  @moduledoc """
  Reciprocal Rank Fusion (#595). Pure ranking math — merges the keyword and
  vector legs by rank position, so the two legs' incompatible score scales
  (ts_rank_cd vs cosine) never need to be reconciled.
  """
  use ExUnit.Case, async: true

  alias Engram.Search.Rrf

  test "an id ranked by both legs beats an id ranked by only one" do
    vector = ["a", "b", "c"]
    keyword = ["b", "d"]

    fused = Rrf.fuse([vector, keyword])
    order = Enum.map(fused, fn {id, _score} -> id end)

    # `b` is #2 in vector and #1 in keyword → highest combined.
    assert hd(order) == "b"
    # every id from both legs survives the fusion, de-duplicated.
    assert Enum.sort(order) == ["a", "b", "c", "d"]
  end

  test "uses 1/(k+rank) with k defaulting to 60" do
    # Single leg, single id at rank 1 → 1/(60+1).
    assert [{"x", score}] = Rrf.fuse([["x"]])
    assert_in_delta score, 1.0 / 61.0, 1.0e-9
  end

  test "per-leg weights bias the fusion" do
    vector = ["v"]
    keyword = ["k"]

    # Equal weights: both at rank 1 → tie; weighting keyword higher floats k up.
    weighted = Rrf.fuse([vector, keyword], weights: [1.0, 5.0])
    assert hd(Enum.map(weighted, fn {id, _} -> id end)) == "k"
  end

  test "empty legs fuse to an empty list" do
    assert Rrf.fuse([[], []]) == []
  end
end
