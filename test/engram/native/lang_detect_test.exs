defmodule Engram.Native.LangDetectTest do
  # async: false: the leak and thread-count tests read process-wide counters.
  use ExUnit.Case, async: false

  alias Engram.KeywordIndex.LangDetect

  # Captured from the `lingua` hex package (lingua-rs 1.7.2, rebuilt per call)
  # the day this NIF replaced it, with LangDetect's exact options: 635 texts in
  # ~50 Latin-script languages, prefixes from 5 to 300 chars, language pairs,
  # long repeats past the 2K sample, repo docs, empty/whitespace/digits/emoji,
  # and non-Latin or mixed scripts. `detect` is LangDetect.detect/1's result,
  # `top` the detector's best {language, confidence} on the 2K sample.
  @golden "test/support/fixtures/lang_detect_golden.json"
          |> File.read!()
          |> Jason.decode!()

  setup_all do
    LangDetect.warmup()
    :ok
  end

  test "LangDetect.detect/1 reproduces the hex package on the golden set" do
    for %{"text" => text, "detect" => expected} <- @golden do
      assert LangDetect.detect(text) == (expected && String.to_existing_atom(expected)),
             inspect(text)
    end
  end

  test "top language and confidence match the hex package" do
    for %{"text" => text, "top" => [lang, conf]} <- @golden do
      {got_lang, got_conf} = Engram.Native.lang_detect(String.slice(text, 0, 2_000))
      assert_in_delta got_conf, conf, 1.0e-9, inspect(text)

      # With every confidence 0.0 (no words, or nothing to score) lingua
      # returns its languages in HashSet order, which differs per process.
      if conf > 0, do: assert(Atom.to_string(got_lang) == lang, inspect(text))
    end
  end

  test "edge inputs: empty and whitespace score 0.0, invalid UTF-8 is an ArgumentError" do
    assert {_lang, +0.0} = Engram.Native.lang_detect("")
    assert {_lang, +0.0} = Engram.Native.lang_detect("   \n")
    assert LangDetect.detect("") == nil
    # LangDetect's Latin-script regex already raises on invalid UTF-8 (as it
    # did with the hex package), so this only proves the NIF does not crash.
    assert_raise ArgumentError, fn -> Engram.Native.lang_detect("the cat \xFF sat") end
  end

  describe "memory standard" do
    test "native peak stays bounded once the models are loaded" do
      text =
        String.duplicate("Prose in English with ünïcödé and 東京. ", 60) |> String.slice(0, 2_000)

      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      Engram.Native.lang_detect(text)

      assert_receive {_, ^ref, %{native_peak_bytes: peak, input_bytes: bytes},
                      %{nif: :lang_detect, dirty: true}}

      assert peak <= 100 * bytes + 64_000, "#{peak} for #{bytes} bytes"
    end

    test "repeated calls across languages leak nothing" do
      texts = for %{"text" => t} <- Enum.take_every(@golden, 100), do: String.slice(t, 0, 2_000)

      # Models load lazily per language; touch every one before measuring.
      Enum.each(@golden, &Engram.Native.lang_detect(String.slice(&1["text"], 0, 2_000)))

      Engram.NativeLeak.assert_no_leak(fn -> Enum.each(texts, &Engram.Native.lang_detect/1) end)
    end

    test "detection spawns no OS threads (no rayon pool)" do
      before = threads()
      for %{"text" => t} <- Enum.take(@golden, 50), do: LangDetect.detect(t)
      assert threads() == before
    end
  end

  defp threads, do: "/proc/self/task" |> File.ls!() |> length()
end
