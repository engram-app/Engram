defmodule Engram.Native.NoteMetaTest do
  # async: false — the leak test reads a process-wide counter.
  use ExUnit.Case, async: false

  alias Engram.Notes.Helpers

  # Captured from the Elixir rules this NIF replaced, the day of the swap:
  # hand cases plus 8,000 fuzzed strings built from frontmatter, YAML
  # scalars, quotes, inline tags and Unicode. The inputs avoid code syntax,
  # because code-range detection is the one intended change, tested below.
  @golden "test/support/fixtures/note_meta_golden.json"
          |> File.read!()
          |> Jason.decode!(keys: :atoms)

  test "reproduces the Elixir title and tag rules on the golden set" do
    for %{input: input, title: title, tags: tags} <- @golden do
      assert Helpers.extract_title(input, "dir/File Name.md") == title, inspect(input)
      assert Helpers.extract_tags(input) == tags, inspect(input)
      assert Helpers.extract_title_and_tags(input, "dir/File Name.md") == {title, tags}
    end
  end

  test "extract_title_and_tags/2 equals the two separate calls" do
    for content <- [
          "",
          "# Only a heading",
          "no title, #tag",
          "```\n# not a title #nottag\n```\n# Real #yes\n",
          "---\ntitle: FM\ntags: [a, b]\n---\n# H\n#a #c `#d`",
          "---\ntags: x\n---\n" <> String.duplicate("`code` #t ", 3_000),
          "# 東京 😀 #タグ #emoji😀",
          "#ok \xFF # T\xFF",
          String.duplicate("- item #tag `c`\n", 2_000)
        ] do
      assert Helpers.extract_title_and_tags(content, "a/N.md") ==
               {Helpers.extract_title(content, "a/N.md"), Helpers.extract_tags(content)},
             inspect(content)
    end
  end

  test "invalid UTF-8 is scrubbed, not crashed on" do
    assert Helpers.extract_tags("#ok \xFF #fine") == ["ok", "fine"]
    assert Helpers.extract_title("# T\xFF", "a/N.md") == "T�"
  end

  describe "code ranges follow CommonMark" do
    test "a # comment in a code block is not the title" do
      assert Helpers.extract_title("```sh\n# install\n```\n# Real\n", "a/N.md") == "Real"
      assert Helpers.extract_title("````\n# x\n````\n", "a/N.md") == "N"
    end

    test "tags inside longer fences, indented code and multi-backtick spans are skipped" do
      content = "````\n#a\n````\n``x #b y``\n\n    #c\n\n#d\n"
      assert Helpers.extract_tags(content) == ["d"]
    end
  end

  describe "memory standard" do
    test "native peak stays bounded on large notes" do
      for content <- [
            String.duplicate("```\n#x\n```\n`a` #t `c`\n", 40_000),
            String.duplicate("- item with #tag and `code`\n", 33_000),
            "---\ntags: [a, b]\n---\n" <> String.duplicate("Prose #topic here.\n\n", 50_000)
          ] do
        {_tags, peak} = Engram.Native.note_tags_dirty_nif(content)
        assert peak <= 10 * byte_size(content), "#{peak} for #{binary_part(content, 0, 20)}"
        {_title, peak} = Engram.Native.note_title_dirty_nif(content)
        assert peak <= 10 * byte_size(content)
        {_meta, peak} = Engram.Native.note_meta_dirty_nif(content)
        assert peak <= 10 * byte_size(content)
      end
    end

    test "repeated calls leak nothing" do
      content = "---\ntitle: T\ntags: [a]\n---\n# H\n#x `y`"

      Engram.NativeLeak.assert_no_leak(fn ->
        Engram.Native.note_tags_nif(content)
        Engram.Native.note_title_nif(content)
        Engram.Native.note_meta_nif(content)
      end)
    end

    test "a note up to 16 KB parses on the calling scheduler, a bigger one dirty" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      Helpers.extract_tags(String.duplicate("a", 16_384))
      assert_receive {_, ^ref, _, %{nif: :note_tags, dirty: false}}
      Helpers.extract_tags(String.duplicate("a", 16_385))
      assert_receive {_, ^ref, _, %{nif: :note_tags, dirty: true}}
      Helpers.extract_title_and_tags(String.duplicate("a", 16_384), "x.md")
      assert_receive {_, ^ref, _, %{nif: :note_meta, dirty: false}}
      Helpers.extract_title_and_tags(String.duplicate("a", 16_385), "x.md")
      assert_receive {_, ^ref, _, %{nif: :note_meta, dirty: true}}
    end

    test "title and tags emit [:engram, :nif, :call, :stop]" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      Helpers.extract_title("# a", "x.md")
      Helpers.extract_tags("#a")
      assert_receive {[:engram, :nif, :call, :stop], ^ref, _, %{nif: :note_title}}
      assert_receive {[:engram, :nif, :call, :stop], ^ref, _, %{nif: :note_tags}}
    end
  end
end
