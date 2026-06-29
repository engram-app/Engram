defmodule Engram.KeywordIndex.LangDetect do
  @moduledoc """
  Per-chunk Latin-script language detection, confidence-gated.

  Only text containing Latin-script characters is sent to the detector.
  Pure non-Latin/CJK text returns `nil` immediately (those are script-routed
  elsewhere). Detections below the confidence floor also return `nil`, which
  causes the caller to fall back to raw (unstemmed) token indexing.

  Uses the `Lingua` NIF (precompiled Rust, no build-time Rust required).
  The rustler_precompiled version is overridden to 0.9.x in mix.exs so it
  coexists with the mjml NIF under the same resolved version.
  """

  # Confidence floor — below this we trust raw-only indexing more.
  @floor 0.40

  # lingua language atom → text_stemmer ISO 639-1 atom.
  # Only languages where both libraries overlap; unmapped atoms return nil → raw-only.
  @lang_map %{
    english: :en,
    german: :de,
    french: :fr,
    spanish: :es,
    italian: :it,
    portuguese: :pt,
    dutch: :nl,
    danish: :da,
    finnish: :fi,
    hungarian: :hu,
    romanian: :ro,
    swedish: :sv,
    turkish: :tr,
    catalan: :ca,
    czech: :cs,
    esperanto: :eo,
    estonian: :et,
    indonesian: :id,
    irish: :ga,
    lithuanian: :lt,
    polish: :pl,
    basque: :eu,
    bokmal: :no,
    nynorsk: :no
  }

  @spec detect(String.t()) :: atom() | nil
  def detect(text) when is_binary(text) do
    if latin?(text), do: classify(text), else: nil
  end

  # ---

  defp classify(text) do
    result =
      Lingua.detect(text,
        builder_option: :all_languages_with_latin_script,
        compute_language_confidence_values: true,
        preload_language_models: false
      )

    case result do
      {:ok, [{lang_atom, confidence} | _]} when confidence >= @floor ->
        Map.get(@lang_map, lang_atom)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp latin?(text), do: Regex.match?(~r/\p{Latin}/u, text)
end
