defmodule Engram.KeywordIndex.Tokenizer do
  @moduledoc """
  Language-neutral exact-token tokenizer for the keyword search leg (#595).

  Pipeline: Unicode NFKC normalize → Unicode case-fold → extract word runs
  (`[\\p{L}\\p{N}\\p{M}_]+`, so identifiers like `paddle_api_key` stay whole
  and vocalized non-Latin scripts like Arabic harakat and Hebrew niqqud are
  kept attached to their base letters rather than shattering the word) →
  for CJK runs (no word spaces) emit overlapping character bigrams.

  No stemming: exact-token recall is this leg's job; morphology/semantics are
  the vector leg's (Voyage multilingual embeddings). All plaintext-touching
  logic lives here + `KeywordIndex.QdrantSparse` — the future TEE enclave
  boundary.
  """

  @word_re ~r/[\p{L}\p{N}\p{M}_]+/u

  # Hiragana/Katakana, CJK Ext-A, CJK Unified, Hangul syllables, CJK compat.
  @cjk_re ~r/[\x{3040}-\x{30FF}\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}\x{AC00}-\x{D7AF}\x{F900}-\x{FAFF}]/u

  # Strip combining marks that appear immediately after a Latin base character.
  # This removes casefold artifacts like Turkish İ → i + U+0307 (combining dot)
  # and zalgo-style combining-mark spam on Latin text, without touching Arabic
  # diacritics (harakat), Cyrillic, or precomposed accents on non-Latin scripts.
  @strip_marks ~r/(?<=\p{Latin})\p{Mn}+/u

  @spec tokens(String.t() | any()) :: [String.t()]
  def tokens(text) when is_binary(text) do
    text
    |> String.normalize(:nfkc)
    |> String.downcase(:default)
    |> String.replace(@strip_marks, "")
    |> then(&Regex.scan(@word_re, &1))
    |> Enum.map(&hd/1)
    |> Enum.flat_map(&expand/1)
  end

  def tokens(_), do: []

  # Split a word into maximal CJK / non-CJK runs; CJK → bigrams, other → whole.
  defp expand(word) do
    word
    |> String.graphemes()
    |> Enum.chunk_by(&cjk?/1)
    |> Enum.flat_map(fn [g | _] = run ->
      if cjk?(g), do: bigrams(run), else: [Enum.join(run)]
    end)
  end

  defp bigrams([single]), do: [single]

  defp bigrams(chars) do
    chars
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(&Enum.join/1)
  end

  defp cjk?(grapheme), do: Regex.match?(@cjk_re, grapheme)
end
