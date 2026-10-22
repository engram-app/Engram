defmodule Engram.KeywordIndex.PhrasePairsTest do
  @moduledoc """
  Phrase features on the keyword leg (keyword v4). The v5 eval lost
  quoted-phrase queries ("This will reduce the size of") because BM25 over
  unigrams ignores word order: a merged chunk holding the same words in
  other sections outranked the chunk holding the phrase. Documents now also
  carry adjacent-word pair dims; a query asks for them only inside double
  quotes, so an unquoted query is unchanged.
  """
  use ExUnit.Case, async: true

  doctest Engram.KeywordIndex

  alias Engram.KeywordIndex
  alias Engram.KeywordIndex.{Bm25, QdrantSparse, Tokenizer}

  @key :crypto.strong_rand_bytes(32)
  @avgdl 10.0

  describe "quoted_phrases/1" do
    test "straight and smart quotes, several spans" do
      assert KeywordIndex.quoted_phrases(~s(a "one two" b "three four")) == [
               "one two",
               "three four"
             ]

      assert KeywordIndex.quoted_phrases("a “one two” b") == ["one two"]
    end

    # German/Polish low-9 openers, guillemets (French, Russian) and the
    # fullwidth quote a CJK keyboard types: each is a double quote too.
    test "non-English double quotes" do
      for q <- [
            "a „one two“ b",
            "a „one two” b",
            "a « one two » b",
            "a »one two« b",
            "a ＂one two＂ b",
            "a ‟one two” b"
          ] do
        assert KeywordIndex.quoted_phrases(q) |> Enum.map(&String.trim/1) == ["one two"],
               inspect(q)
      end
    end

    test "no quotes, an unbalanced quote, and an empty pair are no phrases" do
      for q <- ["plain words", ~s(open "never closed), "“dangling", ~s(a "" b), ""] do
        assert KeywordIndex.quoted_phrases(q) == [], inspect(q)
      end

      # One unclosed quote voids every span, not just the last.
      assert KeywordIndex.quoted_phrases(~s("x y" "z)) == []
    end
  end

  describe "documents" do
    test "a chunk carries a BM25 weight for each adjacent raw pair" do
      {%{indices: i, values: v}, 4} =
        QdrantSparse.encode_document("Reduce the size, reduce", @key, @avgdl, :en)

      got = Map.new(Enum.zip(i, v))
      w1 = Bm25.tf_weight(1, 4, @avgdl)

      # Pairs cross punctuation (word runs only) and are ordered.
      for {a, b} <- [{"reduce", "the"}, {"the", "size"}, {"size", "reduce"}],
          do: assert_in_delta(got[QdrantSparse.pair_dim(@key, a, b)], w1, 1.0e-9)

      refute Map.has_key?(got, QdrantSparse.pair_dim(@key, "size", "the"))
      # Stems are not paired: the raw stream is.
      refute Map.has_key?(got, QdrantSparse.pair_dim(@key, "reduc", "the"))
    end

    test "the unigram weights are exactly the pre-phrase encoding" do
      text = "This will reduce the size of the build, running fast"
      {new, _} = QdrantSparse.encode_document(text, @key, @avgdl, :en)
      old = old_encode(text, :en)
      new = Map.new(Enum.zip(new.indices, new.values))

      for {d, w} <- old, do: assert_in_delta(new[d], w, 1.0e-9)
      assert map_size(new) == map_size(old) + length(pair_dims(text))
    end

    test "CJK tokens are not paired (they are already char bigrams)" do
      {%{indices: i}, _} = QdrantSparse.encode_document("東京 tower 大阪", @key, @avgdl, nil)
      assert length(i) == 3
    end
  end

  describe "queries" do
    test "an unquoted query is the unigram vector, unchanged (golden)" do
      q = "reduce the size of"
      dims = q |> Tokenizer.tokens(:en) |> Enum.map(&QdrantSparse.dim(@key, &1)) |> Enum.uniq()

      assert QdrantSparse.encode_query(q, @key, :en) ==
               %{indices: Enum.sort(dims), values: List.duplicate(1.0, length(dims))}
    end

    test "a quoted query adds exactly its phrase's pair dims" do
      plain = QdrantSparse.encode_query("fix reduce the size", @key, :en)
      quoted = QdrantSparse.encode_query(~s(fix "reduce the size"), @key, :en)
      pairs = pair_dims("reduce the size")

      assert quoted.indices == Enum.sort(Enum.uniq(plain.indices ++ pairs))
      assert Enum.all?(quoted.values, &(&1 == 1.0))
      # Only words inside the quotes pair: "fix reduce" is not a phrase.
      refute QdrantSparse.pair_dim(@key, "fix", "reduce") in quoted.indices
    end

    test "smart quotes match straight ones; an unbalanced quote is plain" do
      assert QdrantSparse.encode_query("“reduce the size”", @key, :en) ==
               QdrantSparse.encode_query(~s("reduce the size"), @key, :en)

      assert QdrantSparse.encode_query(~s(reduce "the size), @key, :en) ==
               QdrantSparse.encode_query("reduce the size", @key, :en)
    end
  end

  # Qdrant's sparse score: sum over shared dims of query value x IDF x doc
  # weight, IDF computed over the collection (the `modifier: "idf"` formula).
  defp rank(query, docs) do
    n = map_size(docs)

    df =
      docs |> Map.values() |> Enum.flat_map(&Map.keys/1) |> Enum.frequencies()

    score = fn doc ->
      Enum.sum(
        for d <- query.indices, Map.has_key?(doc, d) do
          :math.log(1 + (n - df[d] + 0.5) / (df[d] + 0.5)) * doc[d]
        end
      )
    end

    docs |> Enum.sort_by(fn {_id, doc} -> -score.(doc) end) |> Enum.map(&elem(&1, 0))
  end

  # A merged chunk (v5) holding the phrase's words twice each, in another
  # order, against the chunk holding the phrase itself (the v5 loss, query
  # x232 "This will reduce the size of", in miniature).
  @merged "of size the reduce will this of size the reduce will this"
  @phrase "This will reduce the size of" <>
            " the bundle when every unused locale and debug symbol is stripped"
  @filler ["unrelated notes about gardening", "another page on cooking pasta"]

  test "a quoted phrase ranks the chunk holding it first" do
    docs = %{merged: new_encode(@merged), phrase: new_encode(@phrase)}

    docs =
      Map.merge(
        docs,
        @filler |> Enum.with_index() |> Map.new(fn {t, i} -> {i, new_encode(t)} end)
      )

    unquoted = QdrantSparse.encode_query("This will reduce the size of", @key, nil)
    quoted = QdrantSparse.encode_query(~s("This will reduce the size of"), @key, nil)

    # Today's loss, reproduced: on unigrams the merged chunk wins.
    assert [:merged, :phrase | _] = rank(unquoted, docs)
    assert [:phrase, :merged | _] = rank(quoted, docs)
  end

  # Rollout safety while `Rebuild.target_versions/0` pins keyword 2: stored
  # vectors stay unigram-only until the pass re-encodes them. Pair dims
  # match nothing there, so a quoted query scores and ranks exactly as the
  # same query unquoted, which is today's behaviour.
  test "against old unigram-only vectors a quoted query ranks as today" do
    docs =
      [@merged, @phrase | @filler]
      |> Enum.with_index()
      |> Map.new(fn {t, i} -> {i, old_encode(t, nil)} end)

    unquoted = QdrantSparse.encode_query("This will reduce the size of", @key, nil)
    quoted = QdrantSparse.encode_query(~s("This will reduce the size of"), @key, nil)

    assert quoted.indices != unquoted.indices
    assert rank(quoted, docs) == rank(unquoted, docs)
    assert rank(unquoted, docs) |> hd() == 0
  end

  defp new_encode(text) do
    {%{indices: i, values: v}, _} = QdrantSparse.encode_document(text, @key, @avgdl, nil)
    Map.new(Enum.zip(i, v))
  end

  # The keyword v3 encoding: unigrams only, the stored vectors of every
  # note not yet re-encoded.
  defp old_encode(text, lang) do
    {tokens, len} = Tokenizer.tokens_with_len(text, lang)

    tokens
    |> Enum.frequencies()
    |> Enum.reduce(%{}, fn {t, tf}, acc ->
      w = Bm25.tf_weight(tf, len, @avgdl)
      Map.update(acc, QdrantSparse.dim(@key, t), w, &(&1 + w))
    end)
  end

  defp pair_dims(text) do
    raw = Tokenizer.tokens(text, nil)

    raw
    |> Enum.zip(Enum.drop(raw, 1))
    |> Enum.map(fn {a, b} -> QdrantSparse.pair_dim(@key, a, b) end)
    |> Enum.uniq()
  end
end
