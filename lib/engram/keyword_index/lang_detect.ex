defmodule Engram.KeywordIndex.LangDetect do
  @moduledoc """
  Per-note Latin-script language detection, confidence-gated.

  Only text containing Latin-script characters is sent to the detector.
  Pure non-Latin/CJK text returns `nil` immediately (those are script-routed
  elsewhere). Detections below the confidence floor also return `nil`, which
  causes the caller to fall back to raw (unstemmed) token indexing.

  Uses the `Lingua` NIF (precompiled Rust, no build-time Rust required).
  The rustler_precompiled version is overridden to 0.9.x in mix.exs so it
  coexists with the mjml NIF under the same resolved version.

  ## Memory dial: `low_accuracy_mode`

  lingua-rs loads its n-gram language models into a **process-global** cache
  inside the Rust NIF (loaded lazily on first use, then resident for the node's
  lifetime — a single shared load, NOT per call / per process / per note).

  The footprint depends on which models load:

  | mode | models loaded | resident (all Latin-script langs) |
  |------|---------------|-----------------------------------|
  | full accuracy (default) | uni/bi/tri/quad/five-gram | **~945 MB** |
  | `low_accuracy_mode: true` | **trigram only** | **~55 MB** |

  The load is **one-time and flat**: measured 2026-08-18 by sampling RSS around
  `Lingua.detect/2`, the first call adds ~55 MB and 400 further calls add
  nothing (RSS even drifts down). It is invisible to `:erlang.memory/1` — the
  models live in the NIF, off the BEAM heap — so a BEAM-memory graph alone
  cannot see it, and it is NOT a source of memory *growth* under load. See
  `warmup/0`, which is called at boot so the first indexed note doesn't pay it.

  > The `~135 MB` previously documented here was never reproducible; the
  > measurement above supersedes it.

  Measured on prod (2026-07-03): full accuracy loaded ~945 MB off-heap (invisible
  to `:erlang.memory`), which — on the 1024 MB Fargate task — OOM-crash-looped the
  node whenever indexing ran (see #891/#892). We run **`low_accuracy_mode: true`**:
  ~17x smaller, and coarse language ID is all we need here (we only route to a
  *stemmer*, gated at `@floor` confidence with a raw-index fallback). To trade
  memory back for accuracy, flip the dial below to `false` — but budget ~945 MB
  of resident NIF memory per node and size the task accordingly.
  """

  # Confidence floor — below this we trust raw-only indexing more.
  @floor 0.40

  # Only the first @sample_chars of the text are classified. The NIF rebuilds
  # its detector on every call, so cost is a fixed ~6.5ms floor plus a term
  # proportional to text length. Measured (low_accuracy_mode, all Latin script):
  #
  #     500 chars 7.1ms | 2K 6.5ms | 10K 16.5ms | 50K 50.5ms | 200K 148.2ms
  #
  # i.e. nothing is gained by sampling under 2K, and an unbounded note would pay
  # 20x+ for a coarse stemmer choice that a paragraph already settles.
  @sample_chars 2_000

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
    sample = String.slice(text, 0, @sample_chars)
    if latin?(sample), do: classify(sample), else: nil
  end

  @doc """
  Force the Rust NIF's language models into memory.

  The models are a process-global cache inside the NIF, loaded lazily on the
  first detection and then shared by every caller on the node for its lifetime
  (measured: RSS +55 MB on the first call, then flat across 400 more). Without
  this, the first note indexed after a deploy eats that load on a `DirtyCpu`
  scheduler while a user waits.

  Deliberately goes through `detect/1` rather than `Lingua.init/0`: that NIF
  preloads **all** languages at full n-gram accuracy (~945 MB), which is the
  footprint that OOM-looped the 1 GB task in #891/#892. Routing through
  `detect/1` loads exactly the set `classify/1` uses and nothing more.
  """
  @spec warmup() :: :ok
  def warmup do
    _ = detect("The quick brown fox jumps over the lazy dog.")
    :ok
  end

  # ---

  defp classify(text) do
    result =
      Lingua.detect(text,
        builder_option: :all_languages_with_latin_script,
        # THE memory dial. true => trigram-only models (~55 MB resident) instead
        # of the full uni..five-gram set (~945 MB). See the moduledoc table — this
        # is what keeps the node under its memory limit while indexing. Flip to
        # false only if you also raise the task memory by ~945 MB/node.
        low_accuracy_mode: true,
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
