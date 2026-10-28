defmodule Engram.Search.PhraseCheck do
  @moduledoc """
  Quoted phrases, checked at query time. The keyword vector holds single
  words only (keyword v5 dropped the adjacent-pair dims, 50 to 70% of the
  sparse entries), so word order is verified here instead, on the text the
  search path already loaded and decrypted.

  The top `candidates/0` fused hits are checked with the indexer's own
  tokenizer (`Engram.Native.phrase_matches_nif/4`: same normalisation,
  stemming and CJK bigrams, not a substring test). Hits that hold more of the
  quoted phrases move above the rest; the order inside each group is kept and
  nothing is dropped. A hit with no text is simply unverified.

  The reranker, MMR and the page cut all read `:score`, so a verified hit's
  score is lifted by the head's score range times the phrases it holds: it
  then sorts above every unverified hit, and above a hit with fewer phrases.
  """

  # Fused candidates checked, and the text read from each. A floor point holds
  # a whole note (up to 1 MiB), so a phrase past `@max_text_bytes` of one
  # stays unverified rather than costing a megabyte of tokenizing per hit.
  @candidates 100
  @max_text_bytes 65_536

  @doc "How many fused candidates are checked (and so fetched for a quoted query)."
  # No @spec: the body is a literal, so dialyzer rejects any wider contract.
  def candidates, do: @candidates

  @spec promote([map()], [String.t()], atom() | nil) :: [map()]
  def promote(candidates, [], _language), do: candidates
  def promote([], _phrases, _language), do: []

  def promote(candidates, phrases, language) do
    {head, tail} = Enum.split(candidates, @candidates)
    texts = Enum.map(head, &(Map.get(&1, :text) || ""))

    counts =
      Engram.Native.phrase_matches_nif(
        texts,
        phrases,
        Engram.KeywordIndex.Tokenizer.lang(language),
        @max_text_bytes
      )

    scores = for c <- head, is_number(c[:score]), do: c.score
    bonus = if scores == [], do: 0.0, else: Enum.max(scores) - Enum.min(scores) + 1.0e-9

    promoted =
      head
      |> Enum.zip(counts)
      |> Enum.with_index()
      |> Enum.sort_by(fn {{_c, n}, _i} -> -n end)
      |> Enum.with_index()
      |> Enum.map(fn {{{c, n}, from}, to} -> {lift(c, n, bonus), n > 0 and to < from} end)

    :telemetry.execute(
      [:engram, :search, :phrase_check],
      %{checked: length(head), promoted: Enum.count(promoted, &elem(&1, 1))},
      %{}
    )

    Enum.map(promoted, &elem(&1, 0)) ++ tail
  end

  defp lift(%{score: score} = c, n, bonus) when n > 0 and is_number(score),
    do: %{c | score: score + n * bonus}

  defp lift(c, _n, _bonus), do: c
end
