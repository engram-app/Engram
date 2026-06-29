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
    %{indices: indices, values: values} =
      QdrantSparse.encode_document("alpha alpha beta", key, 3, 3.0)

    assert length(indices) == 2
    assert length(values) == 2
    assert Enum.all?(indices, &(is_integer(&1) and &1 >= 0))
    assert Enum.all?(values, &is_float/1)
    # 'alpha' (tf=2) outweighs 'beta' (tf=1)
    by_dim = Enum.zip(indices, values) |> Map.new()
    assert by_dim[QdrantSparse.dim(key, "alpha")] > by_dim[QdrantSparse.dim(key, "beta")]
  end

  test "encode_query gives unit values, deduped dims", %{key_a: key} do
    %{indices: indices, values: values} = QdrantSparse.encode_query("beta beta", key)
    assert indices == [QdrantSparse.dim(key, "beta")]
    assert values == [1.0]
  end

  test "empty text encodes to empty sparse vector", %{key_a: key} do
    assert QdrantSparse.encode_document("", key, 0, 10.0) == %{indices: [], values: []}
  end

  test "a stemmed document and a stemmed query share a dimension (recall)", %{key_a: key} do
    doc = QdrantSparse.encode_document("running fast", key, 2, 10.0, :en)
    q = QdrantSparse.encode_query("run", key, :en)
    assert Enum.any?(q.indices, &(&1 in doc.indices))
  end

  test "language nil preserves raw-only behavior", %{key_a: key} do
    assert QdrantSparse.encode_query("running", key, nil) ==
             QdrantSparse.encode_query("running", key)
  end
end
