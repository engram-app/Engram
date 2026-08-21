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

  @doc """
  Encode a document chunk's plaintext into a BM25-weighted sparse vector.

  Returns the vector *and* the chunk's raw token count — the impl derives the
  length normalizer from the tokens it already produced, so the caller never
  tokenizes a second time just to count.
  """
  @callback encode_document(
              text :: String.t(),
              filter_key :: binary(),
              avgdl :: float(),
              language :: atom() | nil
            ) :: {sparse(), doc_len :: non_neg_integer()}

  @doc "Encode a query string into a sparse query vector (unit values)."
  @callback encode_query(query :: String.t(), filter_key :: binary(), language :: atom() | nil) ::
              sparse()

  @doc "The configured keyword-index adapter."
  @spec module() :: module()
  def module, do: Application.get_env(:engram, :keyword_index, Engram.KeywordIndex.QdrantSparse)
end
