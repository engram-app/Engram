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

  # Bounded NIF calls. Each call runs on a dirty CPU scheduler, which cannot
  # be preempted and is shared with lingua and md_outline (prod has ONE). 256
  # chunks of at most 2 KB keeps a call well under a second; the token -> dim
  # memo just restarts per batch.
  @docs_per_call 256
  # A query's keyword leg reads this many characters. Search input is
  # otherwise bounded only by the request body limit, and NIF memory and
  # time scale with it.
  @query_chars 4096

  # Vectors come back PACKED (u32 LE indices ascending, f64 LE values) so a
  # note's worth sits off-heap; see `Engram.Native` for the memory accounting.
  #
  # Guards: a non-32-byte key would make dims a reversible hash of the token,
  # and avgdl <= 0 would silently zero every weight. Both raised before the
  # encoder moved to Rust, and still do.
  @impl Engram.KeywordIndex
  def encode_documents(texts, filter_key, avgdl, language)
      when byte_size(filter_key) == 32 and is_number(avgdl) and avgdl > 0 do
    lang = Tokenizer.lang(language)

    texts
    |> Enum.chunk_every(@docs_per_call)
    |> Enum.flat_map(fn batch ->
      for {indices, values, doc_len} <-
            Engram.Native.encode_documents(batch, filter_key, avgdl / 1, lang),
          do: {%{indices: indices, values: values}, doc_len}
    end)
  end

  @impl Engram.KeywordIndex
  def encode_query(query, filter_key, language) when byte_size(filter_key) == 32 do
    {indices, values} =
      query
      |> String.slice(0, @query_chars)
      |> Engram.Native.encode_query_nif(filter_key, Tokenizer.lang(language))

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
