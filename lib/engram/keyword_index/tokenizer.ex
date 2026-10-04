defmodule Engram.KeywordIndex.Tokenizer do
  @moduledoc """
  Keyword tokenizer for the sparse-search leg (#595), implemented in Rust
  (`native/engram_native/src/tokenizer.rs`).

  Pipeline: Unicode NFKC normalize → lowercase → strip Latin casefold
  artifacts (combining marks after Latin base chars) → extract word runs
  (`[\\p{L}\\p{N}\\p{M}_]+`, keeps identifiers whole and keeps Arabic
  harakat / Hebrew niqqud attached) → for CJK runs emit overlapping bigrams;
  for all other runs emit `[raw]` (language nil) or `[raw, stem]` deduped
  (language atom, e.g. `:en`). Non-Latin scripts route to their own Snowball
  stemmer (Cyrillic → :ru, Greek → :el, Arabic → :ar).

  All plaintext-touching logic lives in the NIF — the future TEE enclave
  boundary.
  """

  @type lang :: atom() | nil

  @spec tokens(String.t() | any(), lang()) :: [String.t()]
  def tokens(text, language \\ nil), do: text |> tokens_with_len(language) |> elem(0)

  @doc """
  `{tokens, raw_len}`, where `raw_len == length(tokens(text, nil))`: the
  dual-emit list for the sparse vector, and the raw count for BM25 length
  normalization and `chunks.token_count`, from one pass.
  """
  @spec tokens_with_len(String.t() | any(), lang()) :: {[String.t()], non_neg_integer()}
  def tokens_with_len(text, language \\ nil)

  def tokens_with_len(text, language) when is_binary(text),
    do: Engram.Native.tokens_with_len(text, lang(language))

  def tokens_with_len(_, _), do: {[], 0}

  @doc false
  def lang(nil), do: nil
  def lang(language) when is_atom(language), do: Atom.to_string(language)
end
