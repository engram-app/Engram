defmodule Engram.KeywordIndex.Bm25Test do
  use ExUnit.Case, async: true

  alias Engram.KeywordIndex.Bm25

  test "term frequency saturates (k1) — doubling tf less than doubles weight" do
    w1 = Bm25.tf_weight(1, 100, 100.0)
    w2 = Bm25.tf_weight(2, 100, 100.0)
    assert w2 > w1
    assert w2 < 2 * w1
  end

  test "length normalization (b): a longer doc scores a term lower" do
    short = Bm25.tf_weight(1, 50, 100.0)
    long = Bm25.tf_weight(1, 200, 100.0)
    assert short > long
  end

  test "a doc at avgdl uses the neutral normalization factor" do
    # norm = 1 - b + b*(len/avgdl) = 1 when len == avgdl
    assert_in_delta Bm25.tf_weight(1, 100, 100.0), 1 * 2.2 / (1 + 1.2 * 1.0), 1.0e-9
  end

  test "k1/b are overridable" do
    assert Bm25.tf_weight(3, 100, 100.0, k1: 0.0) == 1.0
  end
end
