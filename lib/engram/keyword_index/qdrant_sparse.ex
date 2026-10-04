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
  alias Engram.KeywordIndex.Tokenizer

  @doc """
  HMAC(filter_key, token) → unsigned u32 sparse dimension index. The NIF
  computes the same thing; this is the reference the tests hold it to.
  """
  @spec dim(binary(), String.t()) :: non_neg_integer()
  def dim(filter_key, token) do
    <<u32::unsigned-integer-size(32), _rest::binary>> = Crypto.hmac_field(filter_key, token)
    u32
  end

  # Convenience arity (language defaults to nil = raw-only).
  def encode_document(text, filter_key, avgdl),
    do: encode_document(text, filter_key, avgdl, nil)

  def encode_query(query, filter_key), do: encode_query(query, filter_key, nil)

  # Single-text convenience, unpacked to plain lists.
  def encode_document(text, filter_key, avgdl, language) do
    [{packed, doc_len}] = encode_documents([text], filter_key, avgdl, language)
    {unpack(packed), doc_len}
  end

  # The whole note in one NIF call (dirty CPU scheduler). Vectors come back
  # PACKED (u32 LE indices ascending, f64 LE values) so a note's worth sits
  # off-heap; see `Engram.Native` for the memory accounting.
  @impl Engram.KeywordIndex
  def encode_documents(texts, filter_key, avgdl, language) do
    for {indices, values, doc_len} <-
          Engram.Native.encode_documents(texts, filter_key, avgdl / 1, Tokenizer.lang(language)),
        do: {%{indices: indices, values: values}, doc_len}
  end

  @impl Engram.KeywordIndex
  def encode_query(query, filter_key, language) do
    {indices, values} =
      Engram.Native.encode_query_nif(query, filter_key, Tokenizer.lang(language))

    %{indices: indices, values: values}
  end

  @doc "Packed sparse vector (see `encode_documents/4`) back to plain lists."
  @spec unpack(Engram.KeywordIndex.packed_sparse()) :: Engram.KeywordIndex.sparse()
  def unpack(%{indices: indices, values: values}) do
    %{
      indices: for(<<d::unsigned-little-32 <- indices>>, do: d),
      values: for(<<w::float-little-64 <- values>>, do: w)
    }
  end
end
