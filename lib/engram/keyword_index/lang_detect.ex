defmodule Engram.KeywordIndex.LangDetect do
  @moduledoc """
  Per-note Latin-script language detection, confidence-gated.

  Only text containing Latin-script characters is sent to the detector.
  Pure non-Latin/CJK text returns `nil` immediately (those are script-routed
  elsewhere). Detections below the confidence floor also return `nil`, which
  causes the caller to fall back to raw (unstemmed) token indexing.

  Uses lingua-rs 1.7.2 inside `Engram.Native` (`lang_detect`), the same
  crate and models the `lingua` hex package wrapped, but with ONE detector
  built for the node's lifetime. The hex NIF built a new detector per call.

  ## Memory dial: `low_accuracy_mode`

  lingua-rs loads its n-gram language models into a **process-global** cache
  inside the Rust NIF (loaded lazily on first use, then resident for the node's
  lifetime: a single shared load, NOT per call / per process / per note).
  Since the move into `Engram.Native` they are allocated through `enif_alloc`,
  so `:erlang.memory(:system)` counts them.

  The footprint depends on which models load:

  | mode | models loaded | resident (all Latin-script langs) |
  |------|---------------|-----------------------------------|
  | full accuracy (default) | uni/bi/tri/quad/five-gram | **~945 MB** |
  | `low_accuracy_mode: true` | **trigram only** | **~55 MB** |

  The load is **one-time and flat**: measured 2026-08-18 by sampling RSS around
  the hex package's `Lingua.detect/2`, the first call adds ~55 MB and 400
  further calls add nothing (RSS even drifts down). It is NOT a source of
  memory *growth* under load. See `warmup/0`, which is called at boot so the
  first indexed note doesn't pay it.

  > The `~135 MB` previously documented here was never reproducible; the
  > measurement above supersedes it.

  Measured on prod (2026-07-03): full accuracy loaded ~945 MB off-heap (invisible
  to `:erlang.memory`), which — on the 1024 MB Fargate task — OOM-crash-looped the
  node whenever indexing ran (see #891/#892). We run **`low_accuracy_mode: true`**:
  ~17x smaller, and coarse language ID is all we need here (we only route to a
  *stemmer*, gated at `@floor` confidence with a raw-index fallback). To trade
  memory back for accuracy, drop `.with_low_accuracy_mode()` in
  `native/engram_native/src/lang_detect.rs`, but budget ~945 MB
  of resident NIF memory per node and size the task accordingly.
  """

  # Confidence floor — below this we trust raw-only indexing more.
  @floor 0.40

  # Only the first @sample_chars of the text are classified: cost grows with
  # text length, and an unbounded note would pay 20x+ for a coarse stemmer
  # choice that a paragraph already settles. Measured with the old hex NIF:
  #
  #     500 chars 7.1ms | 2K 6.5ms | 10K 16.5ms | 50K 50.5ms | 200K 148.2ms
  #
  # The sample also bounds what each NIF call receives (docs/context/native-nifs.md).
  @sample_chars 2_000

  # lingua language atom → Snowball stemmer code (`Engram.Native.stem_languages/0`).
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

  Deliberately goes through `detect/1` rather than preloading: lingua's
  preload reads full n-gram accuracy (~945 MB), the footprint that OOM-looped
  the 1 GB task in #891/#892. Routing through `detect/1` loads exactly the
  trigram set `classify/1` uses and nothing more.
  """
  @spec warmup() :: :ok
  def warmup do
    _ = detect("The quick brown fox jumps over the lazy dog.")
    :ok
  end

  # ---

  # THE memory dial (low accuracy mode, trigram models only) lives in
  # native/engram_native/src/lang_detect.rs. See the moduledoc table.
  defp classify(text) do
    case Engram.Native.lang_detect(text) do
      {lang_atom, confidence} when confidence >= @floor -> Map.get(@lang_map, lang_atom)
      _ -> nil
    end
  end

  defp latin?(text), do: Regex.match?(~r/\p{Latin}/u, text)
end
