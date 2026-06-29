defmodule Engram.KeywordIndex.LangDetect do
  @moduledoc """
  Per-chunk Latin-script language detection, confidence-gated.

  Only text containing Latin-script characters is sent to the detector.
  Pure non-Latin/CJK text returns `nil` immediately (those are script-routed
  elsewhere). Detections below the confidence floor also return `nil`, which
  causes the caller to fall back to raw (unstemmed) token indexing.

  Uses `Paasaa` (pure-Elixir n-gram model) rather than a NIF to avoid
  dependency conflicts with other NIF-based packages in the project.
  """

  # Confidence floor — below this we trust raw-only indexing more.
  @floor 0.50

  # paasaa ISO 639-3 → text_stemmer ISO 639-1 (only languages where both
  # libraries overlap; unmapped codes return nil → raw-only, never crash).
  @lang_map %{
    "eng" => :en,
    "deu" => :de,
    "fra" => :fr,
    "spa" => :es,
    "ita" => :it,
    "por" => :pt,
    "nld" => :nl,
    "dan" => :da,
    "fin" => :fi,
    "hun" => :hu,
    "ron" => :ro,
    "swe" => :sv,
    "tur" => :tr,
    "cat" => :ca,
    "ces" => :cs,
    "epo" => :eo,
    "ekk" => :et,
    "ind" => :id,
    "lit" => :lt,
    "pol" => :pl,
    "nob" => :no,
    "nno" => :no
  }

  @spec detect(String.t()) :: atom() | nil
  def detect(text) when is_binary(text) do
    if latin?(text), do: classify(text), else: nil
  end

  # ---

  defp classify(text) do
    case Paasaa.all(text) do
      [{code, confidence} | _] when confidence >= @floor ->
        Map.get(@lang_map, code)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp latin?(text), do: Regex.match?(~r/\p{Latin}/u, text)
end
