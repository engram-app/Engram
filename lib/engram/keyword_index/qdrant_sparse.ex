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

  # Convenience arity (language defaults to nil = raw-only).
  def encode_document(text, filter_key, avgdl),
    do: encode_document(text, filter_key, avgdl, nil)

  def encode_query(query, filter_key), do: encode_query(query, filter_key, nil)

  def encode_document(text, filter_key, avgdl, language),
    do: hd(encode_documents([text], filter_key, avgdl, language))

  # One token -> dim memo for the whole batch (a note's chunks). The HMAC per
  # (chunk, distinct token) was ~25% of encoding CPU, and a note repeats most
  # of its vocabulary across chunks. The memo lives only for this call, so it
  # is bounded by one note's distinct words and never outlives the key.
  @impl Engram.KeywordIndex
  def encode_documents(texts, filter_key, avgdl, language) do
    {encoded, _dims} =
      Enum.map_reduce(texts, %{}, &encode(&1, filter_key, avgdl, language, &2))

    encoded
  end

  defp encode(text, filter_key, avgdl, language, dims) do
    # `doc_len` is derived here rather than passed in: the caller could only
    # get it by tokenizing the same text a second time, and it must be the RAW
    # count (stems are recall dimensions, not document length). Keeping the
    # derivation next to the tokens that produced it also keeps every
    # plaintext-touching step inside this module + Tokenizer — the future TEE
    # enclave boundary.
    {tokens, doc_len} = Tokenizer.tokens_with_len(text, language)
    norm = Bm25.length_norm(doc_len, avgdl)

    {by_dim, dims} =
      tokens
      |> Enum.frequencies()
      |> Enum.reduce({%{}, dims}, fn {token, tf}, {acc, dims} ->
        {d, dims} = memo_dim(dims, filter_key, token)
        w = Bm25.tf_weight_normed(tf, norm)
        # On a u32 collision, sum the colliding terms' weights.
        {Map.update(acc, d, w, &(&1 + w)), dims}
      end)

    {{to_sparse(by_dim), doc_len}, dims}
  end

  defp memo_dim(dims, filter_key, token) do
    case dims do
      %{^token => d} ->
        {d, dims}

      _ ->
        d = dim(filter_key, token)
        {d, Map.put(dims, token, d)}
    end
  end

  @impl Engram.KeywordIndex
  def encode_query(query, filter_key, language) do
    query
    |> Tokenizer.tokens(language)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn token, acc -> Map.put(acc, dim(filter_key, token), 1.0) end)
    |> to_sparse()
  end

  defp to_sparse(by_dim) do
    {indices, values} = by_dim |> Map.to_list() |> Enum.unzip()
    %{indices: indices, values: values}
  end
end
