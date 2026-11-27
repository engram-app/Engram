defmodule Engram.KeywordStore.FeedKey do
  @moduledoc """
  What the kwsearch feed needs to re-tokenize chunk text: the user's filter
  key and the note's stemmer language. Built only while the feed is written
  (`Engram.KeywordStore.feed?/0`), and handed to the Tantivy backend alone.
  `inspect/1` never shows the key, so a crash report, a log line or an Oban
  error cannot carry it.
  """
  @derive {Inspect, only: [:language]}
  @enforce_keys [:filter_key]
  defstruct [:filter_key, :language]

  @type t :: %__MODULE__{filter_key: binary(), language: String.t() | atom() | nil}

  @doc "A key for the feed, or nil while it is off (callers build nothing then)."
  @spec new(binary(), String.t() | atom() | nil) :: t() | nil
  def new(filter_key, language) do
    if Engram.KeywordStore.feed?(),
      do: %__MODULE__{filter_key: filter_key, language: language},
      else: nil
  end
end
