defmodule Engram.KeywordIndex.QdrantSparseTest do
  use Engram.DataCase, async: true

  alias Engram.Crypto
  alias Engram.KeywordIndex.QdrantSparse
  alias Engram.KeywordIndex.Tokenizer

  setup do
    {:ok, user_a} = insert(:user) |> Crypto.ensure_user_dek()
    {:ok, user_b} = insert(:user) |> Crypto.ensure_user_dek()
    {:ok, key_a} = Crypto.dek_filter_key(user_a)
    {:ok, key_b} = Crypto.dek_filter_key(user_b)
    %{key_a: key_a, key_b: key_b}
  end

  test "dim is a deterministic unsigned u32", %{key_a: key} do
    d = QdrantSparse.dim(key, "paddle_api_key")
    assert d == QdrantSparse.dim(key, "paddle_api_key")
    assert is_integer(d) and d >= 0 and d <= 4_294_967_295
  end

  test "same token under two users yields different dims", %{key_a: a, key_b: b} do
    assert QdrantSparse.dim(a, "secret") != QdrantSparse.dim(b, "secret")
  end

  test "encode_document returns aligned indices/values, no plaintext", %{key_a: key} do
    {%{indices: indices, values: values}, doc_len} =
      QdrantSparse.encode_document("alpha alpha beta", key, 3.0, nil)

    assert doc_len == 3
    assert length(indices) == 2
    assert length(values) == 2
    assert Enum.all?(indices, &(is_integer(&1) and &1 >= 0))
    assert Enum.all?(values, &is_float/1)
    # 'alpha' (tf=2) outweighs 'beta' (tf=1)
    by_dim = Enum.zip(indices, values) |> Map.new()
    assert by_dim[QdrantSparse.dim(key, "alpha")] > by_dim[QdrantSparse.dim(key, "beta")]
  end

  # The batch form returns PACKED vectors and shares a token -> dim memo
  # across a note's chunks. It must equal the per-chunk encoding, and the
  # Elixir HMAC + BM25 math, exactly.
  test "encode_documents is exactly the reference encoding per text", %{key_a: key} do
    texts = [
      "Running fast, running far.",
      "",
      "Ferritin ferritin İstanbul ﬁle naïve 東京 run",
      "running fast again — and again",
      String.duplicate("alpha beta gamma ", 50),
      # Over 32 distinct terms: a larger map iterates in hash order, not key
      # order, so this is the case that pins the index ORDER, not just the set.
      Enum.map_join(1..120, " ", &"term#{&1} word#{rem(&1, 7)}")
    ]

    for lang <- [nil, :en] do
      expected = Enum.map(texts, &canonical(reference_encode(&1, key, 7.5, lang)))
      batch = QdrantSparse.encode_documents(texts, key, 7.5, lang)

      # Packed (u32 indices, f64 values) so a note's vectors sit off-heap.
      assert Enum.all?(batch, fn {p, _} -> is_binary(p.indices) and is_binary(p.values) end)

      assert Enum.map(batch, fn {p, len} -> canonical({QdrantSparse.unpack(p), len}) end) ==
               expected

      assert Enum.map(texts, &canonical(QdrantSparse.encode_document(&1, key, 7.5, lang))) ==
               expected
    end
  end

  # Qdrant sorts a sparse vector's indices on upsert, so ORDER is not part of
  # the contract; the dim -> value map and doc_len are.
  defp canonical({%{indices: i, values: v}, len}), do: {Map.new(Enum.zip(i, v)), len}

  # The pre-NIF Elixir encoder math, verbatim (HMAC + BM25 in Elixir over the
  # shared tokenizer), holding the Rust HMAC and BM25 to it: one HMAC and one full BM25 weight per
  # (chunk, distinct token). The bar the optimized code must match exactly.
  defp reference_encode(text, key, avgdl, lang, b \\ 0.75, max_len \\ nil) do
    {tokens, doc_len} = Tokenizer.tokens_with_len(text, lang)
    len = if max_len, do: min(doc_len, max_len), else: doc_len

    {indices, values} =
      tokens
      |> Enum.frequencies()
      |> Enum.reduce(%{}, fn {token, tf}, acc ->
        w = Engram.KeywordIndex.Bm25.tf_weight(tf, len, avgdl, b: b)
        Map.update(acc, QdrantSparse.dim(key, token), w, &(&1 + w))
      end)
      |> Map.to_list()
      |> Enum.unzip()

    {%{indices: indices, values: values}, doc_len}
  end

  # The NIF hard-codes b = 0.75; `b:` re-encodes with an avgdl that makes
  # its norm equal BM25's at that b, so the weights must match the reference.
  describe "b: (merged v5 groups, plan Task 14.1)" do
    @long String.duplicate("alpha beta gamma delta ", 200) <> "omega"

    test "matches the reference BM25 at that b", %{key_a: key} do
      for b <- [0.0, 0.25, 0.5], text <- [@long, "alpha alpha beta"] do
        [{packed, len}] = QdrantSparse.encode_documents([text], key, 7.5, :en, b: b)
        assert_close({QdrantSparse.unpack(packed), len}, reference_encode(text, key, 7.5, :en, b))
      end
    end

    test "b: 0.75 is the plain encoding", %{key_a: key} do
      assert QdrantSparse.encode_documents([@long], key, 7.5, :en, b: 0.75) ==
               QdrantSparse.encode_documents([@long], key, 7.5, :en)
    end

    test "composes with cap_doc_len: length min(len, 3 x avgdl) at that b", %{key_a: key} do
      [{packed, len}] =
        QdrantSparse.encode_documents([@long], key, 7.5, :en, b: 0.25, cap_doc_len: true)

      assert len > 3 * 7.5
      expected = reference_encode(@long, key, 7.5, :en, 0.25, 3 * 7.5)
      assert_close({QdrantSparse.unpack(packed), len}, expected)
    end

    # The NIF takes b and the length cap itself (review 2094 (a)): a merged
    # or floor document is ONE encode, not an encode plus a re-encode.
    test "b and the length cap cost one NIF call", %{key_a: key} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      QdrantSparse.encode_documents([@long], key, 7.5, :en, b: 0.25, cap_doc_len: true)
      assert_receive {[:engram, :nif, :call, :stop], ^ref, _, %{nif: :keyword_encode}}
      refute_receive {[:engram, :nif, :call, :stop], ^ref, _, %{nif: :keyword_encode}}, 50
    end

    test "a floor point (b 0.75, capped) matches the capped reference", %{key_a: key} do
      [{packed, len}] = QdrantSparse.encode_documents([@long], key, 7.5, :en, cap_doc_len: true)
      expected = reference_encode(@long, key, 7.5, :en, 0.75, 3 * 7.5)
      assert_close({QdrantSparse.unpack(packed), len}, expected)
    end

    test "an empty document stays empty", %{key_a: key} do
      [{packed, 0}] = QdrantSparse.encode_documents([""], key, 7.5, :en, b: 0.0)
      assert QdrantSparse.unpack(packed) == %{indices: [], values: []}
    end
  end

  defp assert_close(actual, expected) do
    {got, len} = canonical(actual)
    {want, ^len} = canonical(expected)
    assert Map.keys(got) == Map.keys(want)
    for {d, w} <- want, do: assert_in_delta(got[d], w, 1.0e-9)
  end

  test "encode_documents of no texts is empty", %{key_a: key} do
    assert QdrantSparse.encode_documents([], key, 7.5, :en) == []
  end

  test "encode_query gives unit values, deduped dims", %{key_a: key} do
    %{indices: indices, values: values} = QdrantSparse.encode_query("beta beta", key)
    assert indices == [QdrantSparse.dim(key, "beta")]
    assert values == [1.0]
  end

  test "empty text encodes to empty sparse vector", %{key_a: key} do
    assert QdrantSparse.encode_document("", key, 10.0, nil) == {%{indices: [], values: []}, 0}
  end

  test "encode_document derives doc_len from the same pass, excluding stems", %{key_a: key} do
    # "running fast" → raw ["running", "fast"]; the :en stem "run" must not
    # inflate the BM25 length normalizer.
    assert {_sparse, 2} = QdrantSparse.encode_document("running fast", key, 10.0, :en)
  end

  test "a stemmed document and a stemmed query share a dimension (recall)", %{key_a: key} do
    {doc, _doc_len} = QdrantSparse.encode_document("running fast", key, 10.0, :en)
    q = QdrantSparse.encode_query("run", key, :en)
    assert Enum.any?(q.indices, &(&1 in doc.indices))
  end

  test "language nil preserves raw-only behavior", %{key_a: key} do
    assert QdrantSparse.encode_query("running", key, nil) ==
             QdrantSparse.encode_query("running", key)
  end

  describe "input bounds (each pins a dirty CPU scheduler otherwise)" do
    # Some generated Snowball stemmers are quadratic in word length: a 200 KB
    # "word" in a search query took 4 s on a non-preemptible scheduler.
    # A token that long is never a real word, so it is indexed raw.
    test "tokens over 64 bytes are not stemmed" do
      long = String.duplicate("running", 10)
      assert Tokenizer.tokens(long, :en) == [long]
      assert Tokenizer.tokens("running", :en) == ["running", "run"]
    end

    test "a query's keyword leg reads at most its first 4096 characters", %{key_a: key} do
      head = Enum.map_join(1..1_000, " ", &"w#{&1}")
      big = String.slice(head <> " " <> String.duplicate("tail ", 20_000), 0, 100_000)

      assert QdrantSparse.encode_query(big, key, :en) ==
               QdrantSparse.encode_query(String.slice(big, 0, 4096), key, :en)
    end

    test "a note is encoded at most 256 chunks per NIF call", %{key_a: key} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      texts = for i <- 1..300, do: "chunk #{i} text"

      assert length(QdrantSparse.encode_documents(texts, key, 7.5, nil)) == 300

      # The handler hears every process's NIF calls (this file is async), so
      # match THIS call's batches by their exact input sizes.
      first = :erlang.iolist_size(Enum.take(texts, 256))
      rest = :erlang.iolist_size(Enum.drop(texts, 256))
      assert_receive {[:engram, :nif, :call, :stop], ^ref, %{input_bytes: ^first}, _}
      assert_receive {[:engram, :nif, :call, :stop], ^ref, %{input_bytes: ^rest}, _}
    end

    # The old Elixir BM25 raised on avgdl <= 0; the NIF would return all-zero
    # weights, silently killing the keyword leg for the note.
    test "a non-positive avgdl is refused, not encoded to zeros", %{key_a: key} do
      assert_raise FunctionClauseError, fn ->
        QdrantSparse.encode_documents(["a b"], key, 0.0, nil)
      end
    end

    # An empty key makes every dim a dictionary-reversible hash of the token.
    test "a filter key that is not 32 bytes is refused" do
      assert_raise FunctionClauseError, fn ->
        QdrantSparse.encode_documents(["a"], <<>>, 1.0, nil)
      end

      assert_raise FunctionClauseError, fn -> QdrantSparse.encode_query("a", <<1, 2>>, nil) end
    end
  end
end
