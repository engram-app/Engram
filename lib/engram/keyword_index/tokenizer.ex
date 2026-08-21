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

  alias Engram.KeywordIndex.StemCache

  @word_re ~r/[\p{L}\p{N}\p{M}_]+/u

  # Hiragana/Katakana, CJK Ext-A, CJK Unified, Hangul syllables, CJK compat.
  #
  # A guard, NOT a regex, and the difference is worth 5% of a bulk upload's CPU.
  # `expand/2` tests every GRAPHEME of every indexed note, and Elixir's
  # `Regex.safe_run/3` calls `Regex.version/0` (`:re.version/0` +
  # `system_info(:endian)`) on EVERY invocation to guard against a stale PCRE
  # compile. At one call per character that dominated: a 2026-08-20 prod profile
  # of a 1.7k-note upload put `Regex.version/0` alone at 43s and the surrounding
  # `Regex.safe_run/3` at 106s. Integer range tests have no such preamble.
  defguardp is_cjk(cp)
            when cp in 0x3040..0x30FF or cp in 0x3400..0x4DBF or cp in 0x4E00..0x9FFF or
                   cp in 0xAC00..0xD7AF or cp in 0xF900..0xFAFF

  # Strip combining marks that appear immediately after a Latin base character.
  # This removes casefold artifacts like Turkish İ → i + U+0307 (combining dot)
  # and zalgo-style combining-mark spam on Latin text, without touching Arabic
  # diacritics (harakat), Cyrillic, or precomposed accents on non-Latin scripts.
  @strip_marks ~r/(?<=\p{Latin})\p{Mn}+/u

  @supported_langs MapSet.new(Text.Stemmer.supported_languages())

  @cyrillic ~r/[\x{0400}-\x{04FF}]/u
  @greek ~r/[\x{0370}-\x{03FF}]/u
  @arabic ~r/[\x{0600}-\x{06FF}\x{0750}-\x{077F}]/u

  @type lang :: atom() | nil

  @spec tokens(String.t() | any(), lang()) :: [String.t()]
  def tokens(text, language \\ nil), do: text |> tokens_with_len(language) |> elem(0)

  @doc """
  Tokenize, and return the RAW token count alongside the (possibly dual-emit)
  token list — `{tokens, raw_len}`, where `raw_len == length(tokens(text, nil))`.

  Indexing needs both: the dual-emit list for the sparse vector, and the raw
  count for BM25 length normalization (`Bm25.tf_weight/4`) and the persisted
  `chunks.token_count`. Getting the count by tokenizing a second time with
  `language: nil` ran the whole normalize → casefold → strip-marks → scan
  pipeline twice for every indexed chunk; only the `emit/2` tail differs
  between the two calls.
  """
  @spec tokens_with_len(String.t() | any(), lang()) :: {[String.t()], non_neg_integer()}
  def tokens_with_len(text, language \\ nil)

  def tokens_with_len(text, language) when is_binary(text) do
    {rev, raw} =
      text
      |> String.normalize(:nfkc)
      |> String.downcase(:default)
      |> String.replace(@strip_marks, "")
      |> then(&Regex.scan(@word_re, &1))
      |> Enum.reduce({[], 0}, fn [word | _], {acc, raw} ->
        {emitted, n} = expand(word, language)
        {Enum.reverse(emitted, acc), raw + n}
      end)

    {Enum.reverse(rev), raw}
  end

  def tokens_with_len(_, _), do: {[], 0}

  # Split a word into maximal CJK / non-CJK runs, returning `{tokens, raw_len}`.
  # CJK runs → overlapping bigrams (never stemmed), each bigram one raw token.
  # Non-CJK runs → dual-emit raw + stem (deduped) when language is set; the
  # stem never counts toward raw_len.
  #
  # The `has_cjk?/1` gate is the whole point: a word with no CJK codepoint
  # chunks into exactly one non-CJK run, so `graphemes |> chunk_by |> join`
  # provably reconstructs the word it was handed. For an all-Latin vault that
  # is three traversals and a rebuilt binary per word to learn nothing.
  defp expand(word, language) do
    if has_cjk?(word) do
      {rev, raw} =
        word
        |> String.graphemes()
        |> Enum.chunk_by(&cjk?/1)
        |> Enum.reduce({[], 0}, fn [g | _] = run, {acc, raw} ->
          if cjk?(g) do
            bi = bigrams(run)
            {Enum.reverse(bi, acc), raw + length(bi)}
          else
            {Enum.reverse(emit(Enum.join(run), language), acc), raw + 1}
          end
        end)

      {Enum.reverse(rev), raw}
    else
      {emit(word, language), 1}
    end
  end

  defp emit(token, nil), do: [token]

  defp emit(token, language) do
    case stem(token, language) do
      ^token -> [token]
      stemmed -> [token, stemmed]
    end
  end

  # Stem via Snowball/text_stemmer. Routes non-Latin scripts to their default
  # Snowball language before checking support; Latin/other uses the passed language.
  #
  # The pure-ASCII gate short-circuits three `Regex.match?/2` calls per token
  # for the overwhelmingly common case. It cannot change the answer: every
  # codepoint in @cyrillic/@greek/@arabic is >= U+0370, so an all-ASCII token
  # misses all three and falls through to `language` either way.
  defp stem(token, language) do
    lang = if ascii?(token), do: language, else: script_lang(token, language)

    if MapSet.member?(@supported_langs, lang) do
      StemCache.stem(token, lang)
    else
      token
    end
  end

  defp script_lang(token, language) do
    cond do
      Regex.match?(@cyrillic, token) -> :ru
      Regex.match?(@greek, token) -> :el
      Regex.match?(@arabic, token) -> :ar
      true -> language
    end
  end

  defp ascii?(<<cp::utf8, rest::binary>>) when cp < 128, do: ascii?(rest)
  defp ascii?(<<>>), do: true
  defp ascii?(_), do: false

  # "Does this binary hold ANY CJK codepoint" — the same question the old
  # `@cjk_re` asked of a grapheme, so `cjk?/1` keeps its exact semantics
  # (a grapheme is CJK if its base or any combining mark is).
  defp has_cjk?(<<cp::utf8, _rest::binary>>) when is_cjk(cp), do: true
  defp has_cjk?(<<_cp::utf8, rest::binary>>), do: has_cjk?(rest)
  defp has_cjk?(_), do: false

  defp bigrams([single]), do: [single]

  defp bigrams(chars) do
    chars
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(&Enum.join/1)
  end

  defp cjk?(grapheme), do: has_cjk?(grapheme)
end
