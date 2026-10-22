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

  @doc """
  Dim of the adjacent raw-token pair `a b` (phrase features): the HMAC of
  `"\\x01bg " <> a <> " " <> b`. A token is one word run and never holds
  `\\x01` or a space, so no token shares the preimage. Reference for the NIF.
  """
  @spec pair_dim(binary(), String.t(), String.t()) :: non_neg_integer()
  def pair_dim(filter_key, a, b), do: dim(filter_key, "\x01bg " <> a <> " " <> b)

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
  # And this many bytes of text: the encoder's token -> dim memo spans the
  # call, so a call over merged (30 KB) or floor (1 MiB) documents held every
  # term of all of them at once. Ordinary chunks never reach it (256 x 2.5 KB).
  @bytes_per_call 1_048_576
  # A query's keyword leg reads this many characters. Search input is
  # otherwise bounded only by the request body limit, and NIF memory and
  # time scale with it.
  @query_chars 4096

  # A capped document is scored as if it were at most `@cap_len_avgdls` x
  # avgdl long (review M3): capped at avgdl it had no length penalty at all,
  # so a 1 MB floor point beat a short exact chunk on tf saturation alone.
  @cap_len_avgdls 3

  # Vectors come back PACKED (u32 LE indices ascending, f64 LE values) so a
  # note's worth sits off-heap; see `Engram.Native` for the memory accounting.
  #
  # Guards: a non-32-byte key would make dims a reversible hash of the token,
  # and avgdl <= 0 would silently zero every weight. Both raised before the
  # encoder moved to Rust, and still do.
  #
  # `cap_doc_len: true` normalizes each document as if it were at most 3 x
  # `avgdl` long (BM25 with `min(doc_len, 3 * avgdl)`). Floor points and
  # capped groups use it: a whole note in one vector would otherwise be
  # buried by length normalization under every short chunk, and with no
  # penalty at all it would outrank them.
  #
  # `b:` (default 0.75) is BM25's length weight, in [0, 1] (the NIF wrapper
  # refuses anything else). Merged v5 groups
  # use a smaller one (plan Task 14.1): at 0.75 a 30 KB group sits 10 to 50x
  # above `avgdl` and is buried on the leg exact queries need.
  #
  # Both go to the NIF, so every document is one encode. The defaults encode
  # exactly as before the options existed.
  @impl Engram.KeywordIndex
  def encode_documents(texts, filter_key, avgdl, language, opts \\ [])
      when byte_size(filter_key) == 32 and is_number(avgdl) and avgdl > 0 do
    lang = Tokenizer.lang(language)
    b = Keyword.get(opts, :b, 0.75)
    cap = if Keyword.get(opts, :cap_doc_len, false), do: @cap_len_avgdls

    texts
    |> calls()
    |> Enum.flat_map(fn batch ->
      for {indices, values, doc_len} <-
            Engram.Native.encode_documents(
              Enum.map(batch, &IO.iodata_to_binary/1),
              filter_key,
              avgdl / 1,
              lang,
              b: b,
              cap: cap
            ),
          do: {%{indices: indices, values: values}, doc_len}
    end)
  end

  # Batches of at most `@docs_per_call` texts and `@bytes_per_call` bytes;
  # a text over the byte budget goes alone.
  defp calls(texts) do
    Enum.chunk_while(
      texts,
      {[], 0, 0},
      fn text, {batch, count, bytes} ->
        size = IO.iodata_length(text)

        if batch != [] and
             (count == @docs_per_call or bytes + size > @bytes_per_call),
           do: {:cont, Enum.reverse(batch), {[text], 1, size}},
           else: {:cont, {[text | batch], count + 1, bytes + size}}
      end,
      fn
        {[], _, _} -> {:cont, {[], 0, 0}}
        {batch, _, _} -> {:cont, Enum.reverse(batch), {[], 0, 0}}
      end
    )
  end

  # Words inside double quotes also add their adjacent-pair dims, which only
  # documents holding those words in that order carry. An unquoted query
  # encodes exactly as before phrases existed.
  @impl Engram.KeywordIndex
  def encode_query(query, filter_key, language) when byte_size(filter_key) == 32 do
    query = String.slice(query, 0, @query_chars)

    {indices, values} =
      Engram.Native.encode_query_nif(
        query,
        filter_key,
        Tokenizer.lang(language),
        Engram.KeywordIndex.quoted_phrases(query)
      )

    %{indices: indices, values: values}
  end

  @doc "Packed sparse vector (see `encode_documents/5`) back to plain lists."
  @spec unpack(Engram.KeywordIndex.packed_sparse()) :: Engram.KeywordIndex.sparse()
  def unpack(%{indices: indices, values: values}) do
    %{
      indices: for(<<d::unsigned-little-32 <- indices>>, do: d),
      values: for(<<w::float-little-64 <- values>>, do: w)
    }
  end
end
