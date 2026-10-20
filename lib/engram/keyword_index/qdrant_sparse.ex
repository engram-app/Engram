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
  # The b the NIF encodes with: its norm is 0.25 + 0.75 * len / avgdl.
  @nif_b 0.75

  # Vectors come back PACKED (u32 LE indices ascending, f64 LE values) so a
  # note's worth sits off-heap; see `Engram.Native` for the memory accounting.
  #
  # Guards: a non-32-byte key would make dims a reversible hash of the token,
  # and avgdl <= 0 would silently zero every weight. Both raised before the
  # encoder moved to Rust, and still do.
  #
  # `cap_doc_len: true` normalizes each document as if it were at most 3 x
  # `avgdl` long (BM25 with `min(doc_len, 3 * avgdl)`). Floor and merged
  # points use it: a whole note in one vector would otherwise be buried by
  # length normalization under every short chunk, and with no penalty at all
  # it would outrank them. A longer document is encoded a second time with
  # `avgdl = doc_len / 3`; the NIF has no length knob, and that second pass
  # is one point's text.
  #
  # `b:` (default 0.75) is BM25's length weight. Merged v5 groups use a
  # smaller one (plan Task 14.1): at 0.75 a 30 KB group sits 10 to 50x
  # above `avgdl` and is buried on the leg exact queries need. The NIF's b
  # is fixed, so such a document is re-encoded the same way, see
  # `renormalize/7`.
  @impl Engram.KeywordIndex
  def encode_documents(texts, filter_key, avgdl, language, opts \\ [])
      when byte_size(filter_key) == 32 and is_number(avgdl) and avgdl > 0 do
    lang = Tokenizer.lang(language)
    b = Keyword.get(opts, :b, @nif_b)
    cap? = Keyword.get(opts, :cap_doc_len, false)
    unless is_number(b) and b >= 0 and b <= @nif_b, do: raise(ArgumentError, "b: #{inspect(b)}")

    encoded =
      texts
      |> calls()
      |> Enum.flat_map(fn batch ->
        for {indices, values, doc_len} <-
              Engram.Native.encode_documents(
                Enum.map(batch, &IO.iodata_to_binary/1),
                filter_key,
                avgdl / 1,
                lang
              ),
            do: {%{indices: indices, values: values}, doc_len}
      end)

    if cap? or b != @nif_b,
      do: Enum.zip_with(texts, encoded, &renormalize(&1, &2, filter_key, avgdl, lang, b, cap?)),
      else: encoded
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

  # BM25 at `b` over a length `eff` (capped or not) has the norm
  # 1 - b + b * eff / avgdl. The NIF gives the same norm when handed
  # avgdl' = 0.75 * len / (0.75 - b + b * eff / avgdl), so a document that
  # needs it is encoded once more with that avgdl. Positive for any b in
  # [0, 0.75] and len > 0. At b = 0.75 and a capped length this is
  # len / 3, the original cap (kept literal so floor points encode exactly
  # as before).
  # ponytail: a second NIF pass per such document; a `b` argument on the
  # NIF removes it if the keyword encode ever shows up in a profile.
  defp renormalize(text, {_vector, doc_len} = encoded, filter_key, avgdl, lang, b, cap?) do
    eff = if cap?, do: min(doc_len, @cap_len_avgdls * avgdl), else: doc_len

    if doc_len == 0 or (b == @nif_b and eff == doc_len) do
      encoded
    else
      nif_avgdl =
        if b == @nif_b,
          do: doc_len / @cap_len_avgdls,
          else: @nif_b * doc_len / (@nif_b - b + b * eff / avgdl)

      [{indices, values, ^doc_len}] =
        Engram.Native.encode_documents([IO.iodata_to_binary(text)], filter_key, nif_avgdl, lang)

      {%{indices: indices, values: values}, doc_len}
    end
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
