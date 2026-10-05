defmodule Engram.Native.ChunkerTest do
  # async: false — the leak test reads a process-wide counter.
  use ExUnit.Case, async: false

  alias Engram.Parsers.Markdown

  test "chunker_version is 3: the boundary fixes below re-chunk the notes they touch" do
    assert Markdown.chunker_version() == 3
  end

  # #1616: the four section bugs, fixed under one version bump (each bump is a
  # corpus rebuild).
  describe "section boundaries" do
    test "a # line inside a code block is not a heading" do
      content =
        "# Setup\n\nRun this:\n\n```sh\n# install deps\nmix deps.get\n```\n\n### Next\n\nmore"

      chunks = Markdown.parse(content, "a/Setup.md")
      assert Enum.map(chunks, & &1.heading_path) == ["Setup", "Setup > Next"]
      assert hd(chunks).text =~ "# install deps\nmix deps.get"
    end

    test "an H1 after the first keeps its own text in the heading path" do
      content = "# Chapter One\n\nfirst\n\n# Chapter Two\n\nsecond\n\n## Part\n\nthird"
      paths = content |> Markdown.parse("Book.md") |> Enum.map(& &1.heading_path)

      assert paths == [
               "Chapter One",
               "Chapter One > Chapter Two",
               "Chapter One > Chapter Two > Part"
             ]
    end

    test "a heading-only section yields no chunk" do
      chunks = Markdown.parse("# My Note\n## Sub\n\nbody text", "My Note.md")
      assert [%{text: "## Sub\n\nbody text", heading_path: "My Note > Sub"}] = chunks
    end

    test "blank and markup-only sub-chunks are dropped" do
      content = "intro words\n\n" <> String.duplicate(" ", 5000) <> "\n\nouttro words"
      assert content |> Markdown.parse("x.md") |> Enum.all?(&(&1.text =~ ~r/[\p{L}\p{N}]/u))
    end

    test "setext headings split sections" do
      content = "Title\n=====\n\nintro\n\nSection\n-------\n\nbody"
      paths = content |> Markdown.parse("Doc.md") |> Enum.map(& &1.heading_path)
      assert paths == ["Doc", "Doc > Section"]
    end

    test "a closing # sequence is not part of the heading" do
      paths =
        "# T\n\n## Usage ##\n\nbody" |> Markdown.parse("T.md") |> Enum.map(& &1.heading_path)

      assert paths == ["T > Usage"]
    end

    test "trailing spaces and blank-line runs do not reach the chunk text" do
      assert [%{text: "a\n\nb"}] = Markdown.parse("a   \n\n\n\n\nb  ", "x.md")
    end

    test "a setext underline inside a list item is not a heading" do
      content = "- item\n  ---\n\nafter"
      assert [%{heading_path: "x"}] = Markdown.parse(content, "x.md")
    end
  end

  test "invalid UTF-8 is scrubbed, not crashed on" do
    assert [%{text: "a � b"}] = Markdown.parse("a \xFF b", "x.md")
  end

  describe "memory standard" do
    test "native peak stays bounded on large notes" do
      for content <- [
            String.duplicate("## H\n\n" <> String.duplicate("word ", 500) <> "\n\n", 400),
            String.duplicate("```\n# x\n```\ntext\n", 40_000),
            "![i](data:image/png;base64," <>
              Base.encode64(:crypto.strong_rand_bytes(1_500_000)) <> ")"
          ] do
        {_chunks, peak} = Engram.Native.chunk_dirty_nif(content, "f", "T")
        assert peak <= 10 * byte_size(content), "#{peak} for #{binary_part(content, 0, 20)}"
      end
    end

    test "repeated calls leak nothing" do
      args = ["---\ntags: [a]\n---\n# A\n\ntext `c`\n\n## B\n\nmore", "f", "T"]
      apply(Engram.Native, :chunk_nif, args)
      before = Engram.Native.live_bytes()
      for _ <- 1..300, do: apply(Engram.Native, :chunk_nif, args)
      assert Engram.Native.live_bytes() - before == 0
    end

    test "parse emits [:engram, :nif, :call, :stop]" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      Markdown.parse("# a\n\nb", "x.md")
      assert_receive {[:engram, :nif, :call, :stop], ^ref, _, %{nif: :chunk, dirty: false}}
    end
  end

  describe "splitting" do
    defp para(i), do: "Paragraph #{i} " <> String.duplicate("word#{i} ", 60)

    test "a long section splits at paragraph boundaries" do
      content = Enum.map_join(1..12, "\n\n", &para/1)
      chunks = Markdown.parse(content, "x.md")
      assert length(chunks) > 1
      assert Enum.all?(chunks, &(byte_size(&1.text) <= 2048))
      assert Enum.all?(chunks, &String.starts_with?(&1.text, "Paragraph "))
    end

    test "an edit in a huge section changes only nearby chunks" do
      paras = Enum.map(1..300, &para/1)
      before = paras |> Enum.join("\n\n") |> Markdown.parse("x.md") |> MapSet.new(& &1.text)

      edited =
        paras
        |> List.update_at(150, &("inserted words here " <> &1))
        |> Enum.join("\n\n")
        |> Markdown.parse("x.md")
        |> MapSet.new(& &1.text)

      changed = MapSet.size(MapSet.difference(edited, before))
      assert MapSet.size(before) > 30
      assert changed <= 3
    end
  end

  describe "embed_text (#1621)" do
    test "carries the heading path but not the folder" do
      [chunk] = Markdown.parse("# T\n\nbody", "Work/Projects/T.md")
      assert chunk.context_text == "Work/Projects > T\n\n# T\n\nbody"
      assert chunk.embed_text == "T\n\n# T\n\nbody"
    end

    test "moving a note between folders leaves embed_text unchanged" do
      a = Markdown.parse("# T\n\nbody", "A/T.md")
      b = Markdown.parse("# T\n\nbody", "B/T.md")
      assert Enum.map(a, & &1.embed_text) == Enum.map(b, & &1.embed_text)
    end
  end
end
