defmodule Engram.Embedder do
  @moduledoc """
  Behaviour for embedding adapters (Voyage AI, Ollama, OpenAI, etc.).
  Implementations must accept a list of texts and return one vector per text:
  a list of floats, or a packed little-endian float32 binary (Voyage returns
  that for indexing; `Engram.Indexing` accepts both, search expects lists).
  """

  @doc """
  Embed a batch of texts. Returns vectors in the same order as inputs.
  """
  @callback embed_texts([String.t()]) :: {:ok, [[float()] | binary()]} | {:error, term()}

  @doc """
  Embed a batch of texts with options (e.g., model override for asymmetric retrieval).
  """
  @callback embed_texts([String.t()], keyword()) ::
              {:ok, [[float()] | binary()]} | {:error, term()}

  @doc """
  Returns metadata about the embedder: model name and vector dimensions.
  Used for collection setup and diagnostics.
  """
  @callback model_info() :: %{model: String.t(), dimensions: pos_integer()}

  @optional_callbacks [model_info: 0, embed_texts: 2]

  @doc """
  `text` in Unicode NFC, as the voyage tokenizer normalises before it embeds
  (llama.cpp does not, so `Engram.Embedders.Ollama` sends nano NFC text), and
  the key the vector cache hashes (`Engram.Indexing.VectorCache.normalize/1`).
  Not valid UTF-8 has no NFC form: returned as given.
  """
  @spec nfc(binary()) :: binary()
  def nfc(text) when is_binary(text) do
    case :unicode.characters_to_nfc_binary(text) do
      normalized when is_binary(normalized) -> normalized
      _error -> text
    end
  end
end
