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

  # v5 merged groups (plan Task 14.1) score with a smaller b: at b = 0 the
  # weight is pure tf saturation, blind to length.
  test "b = 0 makes the weight independent of doc_len" do
    assert Bm25.tf_weight(2, 10, 100.0, b: 0.0) == Bm25.tf_weight(2, 30_000, 100.0, b: 0.0)
  end

  test "a smaller b penalizes a long doc less" do
    long = &Bm25.tf_weight(1, 3_000, 100.0, b: &1)
    assert long.(0.25) > long.(0.5)
    assert long.(0.5) > long.(0.75)
    assert long.(0.75) == Bm25.tf_weight(1, 3_000, 100.0)
  end

  # Which b a chunk's keyword vector uses. Merged v5 groups (more than one
  # section) use the `:bm25_b_merged` knob.
  describe "Indexing.sparse_opts/1" do
    alias Engram.Indexing
    alias Engram.ServiceConfig

    test "a single chunk keeps the plain encoding" do
      assert Indexing.sparse_opts(%{section_count: 1}) == []
      assert Indexing.sparse_opts(%{text: "no section_count (v3)"}) == []
    end

    test "a merged group uses b 0.25 by default" do
      assert Indexing.sparse_opts(%{section_count: 3}) == [b: 0.25]
    end

    test "a capped group is length-capped and uses the merged b" do
      assert Indexing.sparse_opts(%{merged: true, section_count: 4}) ==
               [cap_doc_len: true, b: 0.25]
    end

    test "a floor point is length-capped at b 0.75" do
      assert Indexing.sparse_opts(%{floor: true}) == [cap_doc_len: true]
    end

    test "the merged b is the :bm25_b_merged knob" do
      ServiceConfig.put_override(:bm25_b_merged, 0.5)
      assert Indexing.sparse_opts(%{section_count: 2}) == [b: 0.5]
    end
  end
end
