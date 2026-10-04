defmodule Engram.KeywordIndex.QdrantSparseTest do
  use Engram.DataCase, async: true

  alias Engram.Crypto
  alias Engram.KeywordIndex.QdrantSparse

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
  defp reference_encode(text, key, avgdl, lang) do
    {tokens, doc_len} = Engram.KeywordIndex.Tokenizer.tokens_with_len(text, lang)

    {indices, values} =
      tokens
      |> Enum.frequencies()
      |> Enum.reduce(%{}, fn {token, tf}, acc ->
        w = Engram.KeywordIndex.Bm25.tf_weight(tf, doc_len, avgdl)
        Map.update(acc, QdrantSparse.dim(key, token), w, &(&1 + w))
      end)
      |> Map.to_list()
      |> Enum.unzip()

    {%{indices: indices, values: values}, doc_len}
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
end
