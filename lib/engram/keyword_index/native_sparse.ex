defmodule Engram.KeywordIndex.NativeSparse do
  @moduledoc """
  `KeywordIndex` adapter backed by the Rust encoder (`Engram.Native`):
  documents AND queries, so both sides tokenize identically. Indices are
  HMAC(user filter key, token) folded to u32; no plaintext token leaves the
  NIF.
  """
  @behaviour Engram.KeywordIndex

  @impl true
  def encode_documents(texts, filter_key, avgdl, language) do
    for {indices, values, doc_len} <-
          Engram.Native.encode_documents(texts, filter_key, avgdl / 1, lang(language)),
        do: {%{indices: indices, values: values}, doc_len}
  end

  @impl true
  def encode_query(query, filter_key, language) do
    {indices, values} = Engram.Native.encode_query_nif(query, filter_key, lang(language))
    %{indices: indices, values: values}
  end

  defp lang(nil), do: nil
  defp lang(language), do: Atom.to_string(language)
end
