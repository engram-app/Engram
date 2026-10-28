defmodule Engram.KeywordIndex.PhraseQueryTest do
  @moduledoc """
  Quoted phrases (keyword v5). v4 stored adjacent-word pair dims (50 to 70%
  of all sparse entries) so a quoted query could match word order in Qdrant.
  v5 drops them: documents are unigram-only again and the phrase is checked
  at query time against the candidates' text (`Engram.Search.PhraseCheck`).
  """
  use ExUnit.Case, async: true

  doctest Engram.KeywordIndex

  alias Engram.KeywordIndex
  alias Engram.KeywordIndex.{QdrantSparse, Tokenizer}
  alias Engram.Search.PhraseCheck

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
    test "a chunk carries unigram dims only, no adjacent-pair dims" do
      text = "Reduce the size, reduce"
      {%{indices: i}, 4} = QdrantSparse.encode_document(text, @key, @avgdl, :en)

      unigrams =
        text |> Tokenizer.tokens(:en) |> Enum.map(&QdrantSparse.dim(@key, &1)) |> Enum.uniq()

      assert Enum.sort(i) == Enum.sort(unigrams)
    end
  end

  describe "queries" do
    test "a quoted query encodes exactly as the same words unquoted" do
      assert QdrantSparse.encode_query(~s(fix "reduce the size"), @key, :en) ==
               QdrantSparse.encode_query("fix reduce the size", @key, :en)

      assert QdrantSparse.encode_query("“reduce the size”", @key, :en) ==
               QdrantSparse.encode_query("reduce the size", @key, :en)
    end
  end

  describe "PhraseCheck.promote/3" do
    defp cand(id, text), do: %{qdrant_id: id, text: text}

    # The input is ranked by score (best first), as the fused legs return it.
    defp scored(cands),
      do: cands |> Enum.with_index() |> Enum.map(fn {c, i} -> Map.put(c, :score, 1 / (i + 1)) end)

    # The reranker, MMR and the page cut sort by score, so the result's
    # scores must descend in the order returned.
    defp ids(cands) do
      scores = for %{score: s} <- cands, do: s
      assert scores == Enum.sort(scores, :desc)
      Enum.map(cands, & &1.qdrant_id)
    end

    # A merged chunk with the same words in another order, ranked FIRST by
    # the fused legs, against the chunk holding the phrase.
    test "the chunk holding the exact phrase outranks same words in another order" do
      cands =
        scored([
          cand(:scrambled, "of size the reduce will this, of size the reduce will this"),
          cand(:exact, "This will reduce the size of the bundle"),
          cand(:other, "gardening")
        ])

      assert ids(PhraseCheck.promote(cands, ["reduce the size"], :en)) ==
               [:exact, :scrambled, :other]
    end

    test "a stemmed form of the phrase matches" do
      cands = scored([cand(:a, "size reduce"), cand(:b, "We were reducing the sizes yesterday")])
      assert ids(PhraseCheck.promote(cands, ["reduce the size"], :en)) == [:b, :a]
    end

    test "verified matches keep their order, unverified follow in theirs; nothing is dropped" do
      cands = scored([cand(1, "no"), cand(2, "red fox"), cand(3, "none"), cand(4, "a red fox")])
      assert ids(PhraseCheck.promote(cands, ["red fox"], :en)) == [2, 4, 1, 3]
    end

    # Two quoted phrases: a chunk holding both outranks one holding a single
    # phrase even when the fused legs ranked it lower. The score lift must keep
    # the returned order score-descending (the reranker and page cut sort by it).
    test "a chunk with more of the quoted phrases outranks one with fewer" do
      cands =
        scored([cand(:one, "red fox"), cand(:two, "red fox and blue whale"), cand(:none, "x")])

      assert ids(PhraseCheck.promote(cands, ["red fox", "blue whale"], :en)) ==
               [:two, :one, :none]
    end

    test "no phrase, no match, empty or missing text leave the order unchanged" do
      cands = [cand(1, "a"), cand(2, ""), %{qdrant_id: 3, text: nil}, %{qdrant_id: 4}]
      assert PhraseCheck.promote(cands, [], :en) == cands
      assert PhraseCheck.promote(cands, ["red fox"], :en) == cands
      assert PhraseCheck.promote([], ["red fox"], :en) == []
    end

    test "a phrase of only punctuation checks nothing" do
      cands = [cand(1, "a"), cand(2, "b")]
      assert PhraseCheck.promote(cands, ["?!"], :en) == cands
    end

    test "non-Latin and CJK text and phrases do not crash and match" do
      cands =
        scored([
          cand(:ru, "Привет мир"),
          cand(:ja, "今日は東京タワーに行きました"),
          cand(:ja2, "東京に行く"),
          cand(:ar, "مرحبا بالعالم")
        ])

      assert ids(PhraseCheck.promote(cands, ["東京タワー"], nil)) == [:ja, :ru, :ja2, :ar]
      assert hd(ids(PhraseCheck.promote(cands, ["Привет мир"], :ru))) == :ru
      assert hd(ids(PhraseCheck.promote(cands, ["بالعالم"], :ar))) == :ar
    end

    test "only the first candidates() are checked; the tail keeps its place" do
      all =
        scored(
          for(i <- 1..PhraseCheck.candidates(), do: cand(i, "x")) ++ [cand(:tail, "red fox")]
        )

      assert ids(PhraseCheck.promote(all, ["red fox"], :en)) == ids(all)
    end

    test "emits checked and promoted counts, never the phrase" do
      ref = make_ref()
      me = self()

      :telemetry.attach(
        ref,
        [:engram, :search, :phrase_check],
        fn _, m, meta, _ -> send(me, {:pc, m, meta}) end,
        nil
      )

      PhraseCheck.promote(scored([cand(1, "no"), cand(2, "red fox")]), ["red fox"], :en)
      assert_receive {:pc, %{checked: 2, promoted: 1}, meta}
      assert meta == %{}
      :telemetry.detach(ref)
    end
  end
end
