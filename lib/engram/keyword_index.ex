defmodule Engram.KeywordIndex do
  @moduledoc """
  Behaviour for the keyword leg of hybrid search (#595): the codec that turns
  plaintext into the sparse vector representation the vector store ranks.

  This is the swap seam. The only impl is `KeywordIndex.QdrantSparse` (HMAC-keyed
  sparse vectors + Qdrant `modifier: "idf"` BM25). A future TEE migration moves
  this module + `KeywordIndex.Tokenizer` inside an enclave; call sites in
  `Engram.Indexing` and `Engram.Search` are unchanged.
  """

  @type sparse :: %{indices: [non_neg_integer()], values: [float()]}

  @typedoc "`sparse` packed: u32 little-endian indices, f64 little-endian values."
  @type packed_sparse :: %{indices: binary(), values: binary()}

  @doc """
  Encode a note's chunks into BM25-weighted sparse vectors, one per text, in
  order. Batched so an impl can share per-note work across chunks.

  Each element is the vector *and* the chunk's raw token count — the impl derives the
  length normalizer from the tokens it already produced, so the caller never
  tokenizes a second time just to count.
  """
  @callback encode_documents(
              texts :: [iodata()],
              filter_key :: binary(),
              avgdl :: float(),
              language :: atom() | nil
            ) :: [{packed_sparse(), doc_len :: non_neg_integer()}]

  # Optional: only floor points and merged v5 chunks call it, and test
  # doubles implement /4.
  @optional_callbacks encode_documents: 5

  @doc """
  `encode_documents/4` with options. `cap_doc_len: true` length-normalizes
  each document as if it were at most 3 x `avgdl` long (floor points and
  capped groups). `b:` (default 0.75) is the BM25 length weight; merged v5
  chunks use a smaller one (`Engram.Indexing.sparse_opts/1`).
  """
  @callback encode_documents(
              texts :: [iodata()],
              filter_key :: binary(),
              avgdl :: float(),
              language :: atom() | nil,
              opts :: keyword()
            ) :: [{packed_sparse(), doc_len :: non_neg_integer()}]

  @doc "Encode a query string into a sparse query vector (unit values)."
  @callback encode_query(query :: String.t(), filter_key :: binary(), language :: atom() | nil) ::
              sparse()

  # Bump when a change alters the keyword vectors stored for UNCHANGED notes:
  # the tokenizer or stemmer, the BM25 weighting, or which text is encoded.
  # `ReconcileEmbeddings` then rebuilds every stale note's keyword vectors in
  # place (`RefreshKeywordVectors`: no embedder call). Do not bump for a change with
  # identical output. A change that moves chunk boundaries is a
  # `Markdown.chunker_version/0` bump instead.
  #
  # NULL (pre-stamp) is stale. 2: the `context_text` prefix (#1615).
  # 3: the v5 rebuild's encoding (pinned per-vault avgdl, merged-chunk BM25
  # `b`; chunker v5 PR-17). 4: adjacent-word pair dims for quoted-phrase
  # queries, riding the same pass. 3 and 4 are reached only under
  # `INDEX_REBUILD=on` (`Engram.Rebuild.target_versions/0` pins 2 until
  # then); the bump is sparse-only, so it adds no Voyage call.
  @version 4

  @doc "Version of the keyword encoding in this build, stamped on `notes.keyword_version`."
  # No @spec, like `Markdown.chunker_version/0`: the body is a literal, so
  # dialyzer rejects any wider contract as a supertype.
  def version, do: @version

  @doc """
  The double-quoted spans of a search query, the phrases the keyword leg
  matches in word order. Smart, low-9 (German), guillemet and fullwidth
  double quotes count as quotes. An odd number of quotes means the user did
  not close one, so it is no phrase at all.

      iex> Engram.KeywordIndex.quoted_phrases(~s(fix "reduce the size" now))
      ["reduce the size"]

      iex> Engram.KeywordIndex.quoted_phrases(~s(unclosed "quote))
      []
  """
  # Every double-quote glyph a keyboard or autocorrect types, folded to `"`:
  # “ ” „ ‟ (smart, German/Polish low-9), « » (guillemets), ＂ (fullwidth).
  @double_quotes ["\u201C", "\u201D", "\u201E", "\u201F", "\u00AB", "\u00BB", "\uFF02"]

  @spec quoted_phrases(String.t()) :: [String.t()]
  def quoted_phrases(query) do
    parts = query |> String.replace(@double_quotes, "\"") |> String.split("\"")

    if rem(length(parts), 2) == 0,
      do: [],
      else: parts |> Enum.drop(1) |> Enum.take_every(2) |> Enum.reject(&(String.trim(&1) == ""))
  end

  @doc "The configured keyword-index adapter."
  @spec module() :: module()
  def module, do: Application.get_env(:engram, :keyword_index, Engram.KeywordIndex.QdrantSparse)
end
