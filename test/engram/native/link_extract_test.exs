defmodule Engram.Native.LinkExtractTest do
  # async: false — the leak test reads a process-wide counter.
  use ExUnit.Case, async: false

  alias Engram.Links.Parser

  # Captured from the Elixir parser this NIF replaced, the day of the swap:
  # hand cases plus 8,000 fuzzed strings built from link syntax, percent
  # escapes (valid and not) and Unicode whitespace. The inputs
  # avoid code syntax (backticks, tildes, 4-space or tab indents), because
  # code-range detection is the one intended change, tested below.
  @golden "test/support/fixtures/links_golden.json"
          |> File.read!()
          |> Jason.decode!(keys: :atoms)

  test "reproduces the regex parser on the golden set" do
    for %{input: input, out: out} <- @golden do
      expected = Enum.map(out, fn l -> %{l | form: String.to_existing_atom(l.form)} end)
      assert Parser.extract(input) == expected, inspect(input)
    end
  end

  describe "code ranges follow CommonMark" do
    test "a 4-backtick fence, an indented block and a multi-backtick span" do
      content = "````\n[[a]]\n````\n``x [[b]] y``\n\n    [[c]]\n\n[[d]]\n"
      assert [%{target: "d"}] = Parser.extract(content)
    end

    test "an unclosed fence runs to the end of the note" do
      assert Parser.extract("[[a]]\n```\n[[b]]\n") |> Enum.map(& &1.target) == ["a"]
    end

    test "a code span may cross a line break" do
      assert Parser.extract("`x\n[[a]]` [[b]]") |> Enum.map(& &1.target) == ["b"]
    end

    test "a fence inside frontmatter does not hide the body" do
      assert [%{target: "a"}] = Parser.extract("---\nx: ```\n---\n[[a]]")
    end
  end

  test "a percent escape that decodes to invalid UTF-8 is scrubbed and reported" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :notes, :utf8_scrub]])

    assert [%{target: "a\uFFFD.md", anchor: "\uFFFD"}] =
             Parser.extract("[l](a%FF.md#%FE)")

    assert_receive {[:engram, :notes, :utf8_scrub], ^ref, %{count: 1}, %{boundary: :write}}
    assert_receive {[:engram, :notes, :utf8_scrub], ^ref, %{count: 1}, %{boundary: :write}}
    refute_receive {[:engram, :notes, :utf8_scrub], ^ref, _, _}
  end

  describe "memory standard" do
    # pulldown-cmark keeps a node per inline item, so the Rust side parses in
    # segments (see links.rs). Without them a 1 MB code-heavy note peaked at
    # 73 MB and a tight list at 36 MB. One huge paragraph has nowhere to cut
    # and still costs ~36x; the regex parser before it took 93 MB of heap.
    test "native peak stays bounded on large notes that have block structure" do
      for content <- [
            String.duplicate("```\n[[x]]\n```\n`a` `b` `c`\n", 40_000),
            String.duplicate("- item with `code` and [[Link]]\n", 33_000),
            String.duplicate("Prose about [[Topic]] and [l](a.md).\n\n", 25_000)
          ] do
        {_matches, peak} = Engram.Native.link_extract_dirty_nif(content, 0xFFFF_FFFF_FFFF_FFFF)
        assert peak <= 10 * byte_size(content), "#{peak} for #{binary_part(content, 0, 20)}"
      end
    end

    test "repeated calls leak nothing" do
      Engram.NativeLeak.assert_no_leak(fn ->
        Engram.Native.link_extract_nif("---\na: 1\n---\n[[x]] `y`", 100)
      end)
    end

    test "extract emits [:engram, :nif, :call, :stop]" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      Parser.extract("[[a]]")

      assert_receive {[:engram, :nif, :call, :stop], ^ref, %{input_bytes: 5},
                      %{nif: :link_extract}}
    end
  end

  describe "the stored-link cap" do
    test "extract keeps the first 20,000 links by position and counts the cut" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :links, :truncated]])
      note = String.duplicate("[[a]] ", 20_005)

      links = Parser.extract(note)
      assert length(links) == 20_000
      assert List.last(links).position == hd(Parser.extract_all(note)).position + 19_999 * 6
      assert_receive {[:engram, :links, :truncated], ^ref, %{count: 1}, _}

      assert length(Parser.extract_all(note)) == 20_005
    end

    # The rename rewrite finds source notes through stored edges: a target
    # whose only link sits past the cap must still get one, or a rename
    # leaves it dangling.
    test "a target first linked past the cap still gets an edge" do
      note = String.duplicate("[[a]] ", 20_005) <> "[[late]]"
      links = Parser.extract(note)
      assert length(links) == 20_001
      assert List.last(links).target == "late"
    end

    test "a note under the cap is untouched and emits nothing" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :links, :truncated]])
      assert length(Parser.extract(String.duplicate("[[a]] ", 100))) == 100
      refute_receive {[:engram, :links, :truncated], ^ref, _, _}, 50
    end

    test "10 MB of links stays small natively (the NIF stops at the limit)" do
      note = String.duplicate("[[a]] ", div(10_000_000, 6))
      {{links, _, cut?}, peak} = Engram.Native.link_extract_dirty_nif(note, 20_000)
      assert length(links) == 20_000 and cut?
      # Measured 151 MB, uncapped 176 MB: the table of raw matches (48 B per
      # match, sorted by position) is the floor; only the BEAM terms stop at
      # the limit (that side was 713 MB for 1.67M links).
      assert peak < 200_000_000, "#{peak}"
    end
  end

  test "16 KB runs on the calling scheduler, a byte more dirty" do
    Engram.NativeScheduled.assert_scheduled(
      :link_extract,
      &Engram.Native.link_extract(String.duplicate("a", &1), 100)
    )
  end
end
