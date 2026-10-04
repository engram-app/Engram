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
        {_matches, peak} = Engram.Native.link_extract_dirty_nif(content)
        assert peak <= 10 * byte_size(content), "#{peak} for #{binary_part(content, 0, 20)}"
      end
    end

    test "repeated calls leak nothing" do
      Engram.Native.link_extract_nif("---\na: 1\n---\n[[x]]")
      before = Engram.Native.live_bytes()
      for _ <- 1..300, do: Engram.Native.link_extract_nif("---\na: 1\n---\n[[x]] `y`")
      assert Engram.Native.live_bytes() - before == 0
    end

    test "extract emits [:engram, :nif, :call, :stop]" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      Parser.extract("[[a]]")

      assert_receive {[:engram, :nif, :call, :stop], ^ref, %{input_bytes: 5},
                      %{nif: :link_extract}}
    end
  end
end
