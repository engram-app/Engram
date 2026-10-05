defmodule Engram.Native.KeywordEncodeTest do
  # async: false — the leak test reads a process-wide counter.
  use ExUnit.Case, async: false

  alias Engram.KeywordIndex.Tokenizer

  @key :crypto.strong_rand_bytes(32)

  # Captured from the Elixir tokenizer this NIF replaced (490 cases: edge
  # cases in every Snowball language, plus real prose in the common ones),
  # the day of the swap. The NIF reproduced every one. It deliberately does
  # NOT match on rare/new codepoints, which the Elixir side classified with
  # OTP's PCRE 8.45 (2021) Unicode tables.
  @golden "test/support/fixtures/keyword_tokens_golden.json"
          |> File.read!()
          |> Jason.decode!()

  test "reproduces the Elixir tokenizer on the golden set" do
    for %{"text" => text, "lang" => lang, "tokens" => tokens, "raw_len" => raw} <- @golden do
      assert Engram.Native.tokens_with_len(text, lang) == {tokens, raw},
             "#{inspect(text)} (#{inspect(lang)})"
    end
  end

  test "every stemmer language is covered by the golden set" do
    covered = @golden |> Enum.map(& &1["lang"]) |> MapSet.new()
    assert MapSet.subset?(MapSet.new(Engram.Native.stem_languages()), covered)
  end

  test "a stem language the NIF does not know falls back to raw tokens" do
    assert Tokenizer.tokens("running dogs", :xx) == ["running", "dogs"]
  end

  describe "memory standard" do
    # Peak per byte is input-shape dependent (measured up to ~30x for one huge
    # CJK word), so callers bound the INPUT: chunks are at most 2 KB, a call
    # takes at most 256 of them, and queries are capped at 4096 characters.
    test "native peak stays bounded for a 2 MB token and for 2,000 chunks" do
      for texts <- [
            [String.duplicate("a", 2_000_000)],
            for(i <- 1..2_000, do: "chunk #{i} " <> String.duplicate("word#{i} ", 100))
          ] do
        {_, peak} = Engram.Native.encode_documents_nif(texts, @key, 300.0, "en")
        assert peak <= 4 * :erlang.iolist_size(texts) + 65_536
      end
    end

    test "repeated calls leak nothing" do
      texts = for i <- 1..20, do: "note #{i} running fast and far"

      Engram.NativeLeak.assert_no_leak(fn ->
        Engram.Native.encode_documents_nif(texts, @key, 300.0, "en")
      end)
    end

    test "every call emits [:engram, :nif, :call, :stop]" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      Engram.Native.encode_documents(["hello world"], @key, 3.0, nil)

      assert_receive {[:engram, :nif, :call, :stop], ^ref,
                      %{duration: d, native_peak_bytes: p, input_bytes: 11},
                      %{nif: :keyword_encode}}

      assert d > 0 and p > 0
    end

    test "memory_snapshot sets RSS against what the BEAM accounts for" do
      snap = Engram.Native.memory_snapshot()
      assert snap.rss > 0
      assert snap.unaccounted == snap.rss - snap.erlang_total
      assert is_integer(snap.nif_live)
    end
  end
end
