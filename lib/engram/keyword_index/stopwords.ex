defmodule Engram.KeywordIndex.Stopwords do
  @moduledoc """
  The one English stopword list (NLTK's English list without contractions):
  the name_terms leg's match gate (`Engram.Search.NameTerms`) drops these
  query words before it requires every remaining word in a name. Words of
  any length that are not on the list are kept (no length rule).

  The sparse keyword leg keeps stopwords on purpose (BM25's idf already
  discounts them), so it does not use this list.
  """

  alias Engram.KeywordIndex.Tokenizer

  @words ~w(a about above after again against all am an and any are as at be because been
            before being below between both but by can did do does doing down during each
            few for from further had has have having he her here hers herself him himself
            his how i if in into is it its itself just me more most my myself no nor not now
            of off on once only or other our ours ourselves out over own same she should so
            some such than that the their theirs them themselves then there these they this
            those through to too under until up very was we were what when where which while
            who whom why will with you your yours yourself yourselves)

  @set MapSet.new(@words)

  @doc "The list, lowercase."
  @spec words() :: [String.t()]
  def words, do: @words

  @doc """
  `text`'s words (the keyword tokenizer's raw tokens: NFKC, lowercase) with
  the stopwords removed, joined by spaces. "" when every word is a stopword.
  """
  @spec drop(String.t()) :: String.t()
  def drop(text) do
    text
    |> Tokenizer.tokens(nil)
    |> Enum.reject(&MapSet.member?(@set, &1))
    |> Enum.join(" ")
  end
end
