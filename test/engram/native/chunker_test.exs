defmodule Engram.Native.ChunkerTest do
  # async: false — the leak test reads a process-wide counter.
  use ExUnit.Case, async: false

  alias Engram.Parsers.Markdown

  # Pins the chunker's output (809 notes, 2,654 chunks: code, setext, quotes,
  # tables, blobs, long sections). A change here re-chunks notes nobody
  # edits only if @chunker_version is bumped too (#1620): bump it, then rerun
  # test/support/fixtures/chunker_golden.gen.exs.
  @golden_path "test/support/fixtures/chunker_golden.json.gz"
  @external_resource @golden_path
  @golden @golden_path |> File.read!() |> :zlib.gunzip() |> Jason.decode!(keys: :atoms)

  test "output matches the golden set for this chunker_version" do
    for %{input: input, path: path, chunks: expected} <- @golden do
      expected =
        Enum.map(expected, fn c ->
          c
          |> Map.drop([:ctx, :emb])
          |> Map.merge(%{context_text: c.ctx <> c.text, embed_text: c.emb <> c.text})
        end)

      assert Markdown.parse(input, path) == expected,
             "chunker output changed for #{inspect(path)}: bump @chunker_version and regenerate"
    end
  end

  # Stamped 5 by the bundled one-time re-chunk (PR-17); see markdown.ex.
  test "chunker_version is 5: prod rebuilds once, with the bundled re-chunk" do
    assert Markdown.chunker_version() == 5
  end

  # Over 512 B: the min512 merge (chunker v5) leaves such a section alone,
  # so these tests still see one chunk per section.
  @pad String.duplicate("filler words ", 45)

  # #1616: the four section bugs, fixed under one version bump (each bump is a
  # corpus rebuild).
  describe "section boundaries" do
    test "a # line inside a code block is not a heading" do
      content =
        "# Setup\n\nRun this: #{@pad}\n\n```sh\n# install deps\nmix deps.get\n```\n\n### Next\n\nmore #{@pad}"

      chunks = Markdown.parse(content, "a/Setup.md")
      assert Enum.map(chunks, & &1.heading_path) == ["Setup", "Setup > Next"]
      assert hd(chunks).text =~ "# install deps\nmix deps.get"
    end

    test "an H1 after the first keeps its own text in the heading path" do
      content =
        "# Chapter One\n\nfirst #{@pad}\n\n# Chapter Two\n\nsecond #{@pad}\n\n## Part\n\nthird #{@pad}"

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

    test "a note of only headings still yields a chunk, so search can find it" do
      assert [%{text: "# Project Phoenix"}] = Markdown.parse("# Project Phoenix\n", "p.md")

      assert [%{text: "# 2026-10-04\n\n## Tasks\n\n## Notes", heading_path: "2026-10-04"}] =
               Markdown.parse("# 2026-10-04\n\n## Tasks\n\n## Notes\n", "d.md")
    end

    test "blank and markup-only sub-chunks are dropped" do
      # 6 KB of table rule rows: split into pieces with no letter or digit.
      content = "intro words\n\n" <> String.duplicate("| - | - |\n", 600) <> "\nouttro words"
      chunks = Markdown.parse(content, "x.md")
      assert Enum.all?(chunks, &(&1.text =~ ~r/[\p{L}\p{N}]/u))
      assert Enum.any?(chunks, &(&1.text =~ "intro words"))
      assert Enum.any?(chunks, &(&1.text =~ "outtro words"))
    end

    test "setext headings split sections" do
      content = "Title\n=====\n\nintro #{@pad}\n\nSection\n-------\n\nbody #{@pad}"
      paths = content |> Markdown.parse("Doc.md") |> Enum.map(& &1.heading_path)
      # "Title" is not the note's title ("Doc"), so it stays in the path.
      assert paths == ["Doc > Title", "Doc > Title > Section"]
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
        {_chunks, peak} = Engram.Native.chunk_dirty_nif(content, "f", "T", [], nil)
        # Measured 0.5-1.8x; 3x catches a regression the 10x standard would not.
        assert peak <= 3 * byte_size(content), "#{peak} for #{binary_part(content, 0, 20)}"
      end
    end

    # A deep heading tree of tiny leaves: every merged member repeated its
    # full breadcrumb, so 4.5 MB of note was 52 MB of text, 65 MB each of
    # context and embed text, and a 337 MB BEAM peak (#2150 review).
    test "a deep heading tree's chunk text stays linear in the note" do
      parents = fn i ->
        Enum.map_join(1..5, fn lvl ->
          String.duplicate("#", lvl) <>
            " Parent heading level #{lvl} group #{i} with a fairly long descriptive title\n\n"
        end)
      end

      # 3k leaves: min512 merging; 30k: past budget/1, coalesced. Under the
      # budget each chunk also carries its <= 512 B prefix twice, so only the
      # coalesced note bounds context and embed text (up to 2,000 chunks).
      for leaves <- [3_000, 30_000] do
        content =
          Enum.map_join(0..(leaves - 1), fn i ->
            if(rem(i, 1000) == 0, do: parents.(div(i, 1000)), else: "") <>
              "###### leaf #{i}\nword#{i}\n\n"
          end)

        chunks = Markdown.parse(content, "f/Tree.md")
        bytes = fn key -> chunks |> Enum.map(&byte_size(Map.fetch!(&1, key))) |> Enum.sum() end
        note = byte_size(content)

        assert bytes.(:text) <= 2 * note, "text #{bytes.(:text)} for #{note}"

        if leaves > 3_000 do
          assert bytes.(:context_text) <= 3 * note, "context #{bytes.(:context_text)}"
          assert bytes.(:embed_text) <= 3 * note, "embed #{bytes.(:embed_text)}"
        end

        # Nothing dropped: every leaf's text is in some chunk.
        assert chunks |> Enum.map(&length(:binary.matches(&1.text, "\nword"))) |> Enum.sum() ==
                 leaves
      end
    end

    # 4.5 MB of heading tree held the one dirty CPU scheduler for 8 s. Over
    # 256 KB a note is chunked a heading segment per dirty call; the chunks
    # are the one call's, past the budget's restart (the 30k tree) too.
    test "a large note chunks in short steps, with the one call's chunks" do
      tree = fn leaves ->
        Enum.map_join(0..(leaves - 1), fn i ->
          if(rem(i, 1000) == 0, do: "# Parent #{i}\n\n## Child #{i}\n\n", else: "") <>
            "###### leaf #{i}\nword#{i}\n\n"
        end)
      end

      for content <- [tree.(12_000), tree.(30_000), "---\na: 1\n---\n" <> tree.(12_000)] do
        assert byte_size(content) > 262_144
        ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
        sliced = Engram.Native.chunk(content, "f", "T", ["al"], "Type: d")
        {whole, _peak} = Engram.Native.chunk_dirty_nif(content, "f", "T", ["al"], "Type: d")
        assert sliced == whole
        assert_receive {[:engram, :nif, :call, :stop], ^ref, _, %{nif: :chunk, sliced: true}}
        :telemetry.detach(ref)
      end
    end

    test "repeated calls leak nothing" do
      args = ["---\ntags: [a]\n---\n# A\n\ntext `c`\n\n## B\n\nmore", "f", "T", ["x"], "lead"]
      Engram.NativeLeak.assert_no_leak(fn -> apply(Engram.Native, :chunk_nif, args) end)
    end

    test "parse emits [:engram, :nif, :call, :stop]" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      Markdown.parse("# a\n\nb", "x.md")
      assert_receive {[:engram, :nif, :call, :stop], ^ref, _, %{nif: :chunk}}
    end
  end

  describe "splitting" do
    defp para(i), do: "Paragraph #{i} " <> String.duplicate("word#{i} ", 60)

    # A run with no space or newline (a CSV line, minified text, comma-joined
    # tags) used to be cut at the byte cap, mid-word: both halves are other
    # tokens, so the word was no longer keyword-findable.
    test "a run with no space is cut between words, not inside one" do
      words = for i <- 1..3_000, do: "word" <> Integer.to_string(i)

      for content <- [
            Enum.join(words, ","),
            "---\nlist: " <> Enum.join(words, ",") <> "\n---\nbody"
          ] do
        found =
          content
          |> Markdown.parse("x.md")
          |> Enum.flat_map(&String.split(&1.text, ~r/[^a-z0-9]+/))
          |> MapSet.new()

        assert Enum.reject(words, &MapSet.member?(found, &1)) == []
      end
    end

    test "a long section splits at paragraph boundaries" do
      content = Enum.map_join(1..12, "\n\n", &para/1)
      chunks = Markdown.parse(content, "x.md")
      assert length(chunks) > 1
      assert Enum.all?(chunks, &(byte_size(&1.text) <= 2048))
      assert Enum.all?(chunks, &String.starts_with?(&1.text, "Paragraph "))
    end

    # #1594: cuts depend only on nearby text. Greedy packing (v2) re-chunked
    # 15-40 chunks per edit and 25-86 per deleted paragraph on these shapes.
    test "an edit or a deleted paragraph re-chunks only its neighbourhood" do
      :rand.seed(:exsss, {1, 2, 3})

      word = fn ->
        for(_ <- 1..(3 + :rand.uniform(6)), into: "", do: <<?a + :rand.uniform(26) - 1>>)
      end

      paras =
        for _ <- 1..300, do: Enum.map_join(1..(10 + :rand.uniform(110)), " ", fn _ -> word.() end)

      texts = fn ps ->
        ps |> Enum.join("\n\n") |> Markdown.parse("x.md") |> MapSet.new(& &1.text)
      end

      before = texts.(paras)
      changed = fn ps -> MapSet.size(MapSet.difference(texts.(ps), before)) end
      at = Enum.take_random(5..290, 10)

      edits = Enum.map(at, fn i -> changed.(List.update_at(paras, i, &("new words " <> &1))) end)
      deletes = Enum.map(at, fn i -> changed.(List.delete_at(paras, i)) end)

      assert MapSet.size(before) > 50
      assert Enum.sum(edits) <= 25, inspect(edits)
      assert Enum.sum(deletes) <= 25, inspect(deletes)
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

  test "16 KB runs on the calling scheduler, a byte more dirty" do
    Engram.NativeScheduled.assert_scheduled(
      :chunk,
      &Engram.Native.chunk(String.duplicate("a", &1), "f", "T")
    )
  end
end
