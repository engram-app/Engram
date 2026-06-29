defmodule Engram.KeywordIndex.Tokenizer do
  @moduledoc """
  Keyword tokenizer for the sparse-search leg (#595).

  Pipeline: Unicode NFKC normalize → Unicode case-fold → strip Latin
  casefold artifacts (combining marks after Latin base chars) → extract word
  runs (`[\\p{L}\\p{N}\\p{M}_]+`, keeps identifiers whole and keeps Arabic
  harakat / Hebrew niqqud attached) → for CJK runs emit overlapping bigrams;
  for all other runs emit `[raw]` (language nil) or `[raw, stem]` deduped
  (language atom, e.g. `:en`).

  CJK bigrams are never stemmed. Non-Latin scripts pass through as raw tokens
  when a language is supplied (stemmer routing for other scripts is Task 6).
  All plaintext-touching logic lives here and in `KeywordIndex.QdrantSparse` —
  the future TEE enclave boundary.
  """

  @word_re ~r/[\p{L}\p{N}\p{M}_]+/u

  # Hiragana/Katakana, CJK Ext-A, CJK Unified, Hangul syllables, CJK compat.
  @cjk_re ~r/[\x{3040}-\x{30FF}\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}\x{AC00}-\x{D7AF}\x{F900}-\x{FAFF}]/u

  # Strip combining marks that appear immediately after a Latin base character.
  # This removes casefold artifacts like Turkish İ → i + U+0307 (combining dot)
  # and zalgo-style combining-mark spam on Latin text, without touching Arabic
  # diacritics (harakat), Cyrillic, or precomposed accents on non-Latin scripts.
  @strip_marks ~r/(?<=\p{Latin})\p{Mn}+/u

  @supported_langs MapSet.new(Text.Stemmer.supported_languages())

  @type lang :: atom() | nil

  @spec tokens(String.t() | any(), lang()) :: [String.t()]
  def tokens(text, language \\ nil)

  def tokens(text, language) when is_binary(text) do
    text
    |> String.normalize(:nfkc)
    |> String.downcase(:default)
    |> String.replace(@strip_marks, "")
    |> then(&Regex.scan(@word_re, &1))
    |> Enum.map(&hd/1)
    |> Enum.flat_map(&expand(&1, language))
  end

  def tokens(_, _), do: []

  # Split a word into maximal CJK / non-CJK runs.
  # CJK runs → overlapping bigrams (never stemmed).
  # Non-CJK runs → dual-emit raw + stem (deduped) when language is set.
  defp expand(word, language) do
    word
    |> String.graphemes()
    |> Enum.chunk_by(&cjk?/1)
    |> Enum.flat_map(fn [g | _] = run ->
      if cjk?(g), do: bigrams(run), else: emit(Enum.join(run), language)
    end)
  end

  defp emit(token, nil), do: [token]

  defp emit(token, language) do
    case stem(token, language) do
      ^token -> [token]
      stemmed -> [token, stemmed]
    end
  end

  # Stem via Snowball/text_stemmer. Only called for supported languages.
  # Non-Latin script routing (e.g. Arabic, Russian) is deferred to Task 6.
  defp stem(token, language) do
    if MapSet.member?(@supported_langs, language) do
      Text.Stemmer.stem(token, language)
    else
      token
    end
  end

  defp bigrams([single]), do: [single]

  defp bigrams(chars) do
    chars
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(&Enum.join/1)
  end

  defp cjk?(grapheme), do: Regex.match?(@cjk_re, grapheme)
end
