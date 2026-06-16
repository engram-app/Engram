defmodule Engram.KeywordIndex.QdrantSparse do
  @moduledoc """
  HMAC-keyed sparse-vector codec for the keyword leg (#595).

  A document chunk becomes `%{indices: [u32], values: [bm25_tf_weight]}` where
  each index is `HMAC(user_DEK_filter_key, token)` folded to an unsigned u32.
  No plaintext token is ever stored — the dims are keyed, non-dictionary-
  reversible fingerprints, scoped per user (so Qdrant's IDF is per-user).

  Collisions (two tokens → same u32; ~1 expected at 100k distinct terms) sum
  their values — graceful, ranking-only degradation. We take the high 32 bits
  of the HMAC directly (NO sign-fold / abs — that halves the space; cf.
  FastEmbed issue #369).
  """
  @behaviour Engram.KeywordIndex

  alias Engram.Crypto
  alias Engram.KeywordIndex.Bm25
  alias Engram.KeywordIndex.Tokenizer

  @doc "HMAC(filter_key, token) → unsigned u32 sparse dimension index."
  @spec dim(binary(), String.t()) :: non_neg_integer()
  def dim(filter_key, token) do
    <<u32::unsigned-integer-size(32), _rest::binary>> = Crypto.hmac_field(filter_key, token)
    u32
  end

  @impl Engram.KeywordIndex
  def encode_document(text, filter_key, doc_len, avgdl) do
    text
    |> Tokenizer.tokens()
    |> Enum.frequencies()
    |> Enum.reduce(%{}, fn {token, tf}, acc ->
      d = dim(filter_key, token)
      w = Bm25.tf_weight(tf, doc_len, avgdl)
      # On a u32 collision, sum the colliding terms' weights.
      Map.update(acc, d, w, &(&1 + w))
    end)
    |> to_sparse()
  end

  @impl Engram.KeywordIndex
  def encode_query(query, filter_key) do
    query
    |> Tokenizer.tokens()
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn token, acc -> Map.put(acc, dim(filter_key, token), 1.0) end)
    |> to_sparse()
  end

  defp to_sparse(by_dim) do
    {indices, values} = by_dim |> Map.to_list() |> Enum.unzip()
    %{indices: indices, values: values}
  end
end
