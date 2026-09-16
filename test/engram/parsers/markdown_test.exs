defmodule Engram.Parsers.MarkdownTest do
  use ExUnit.Case, async: true

  alias Engram.Parsers.Markdown

  @simple_note """
  # Hello World

  This is the intro paragraph.

  ## Section One

  Content of section one.

  ## Section Two

  Content of section two.
  """

  @frontmatter_note """
  ---
  tags: [health, fitness]
  title: My Custom Title
  ---
  # Hello World

  Intro text.

  ## Details

  More content here.
  """

  # ---------------------------------------------------------------------------
  # parse/2 — basic structure
  # ---------------------------------------------------------------------------

  describe "parse/2 basic structure" do
    test "returns list of chunks" do
      chunks = Markdown.parse(@simple_note, "Test/Hello World.md")
      assert is_list(chunks)
      assert chunks != []
    end

    test "each chunk has required fields" do
      [chunk | _] = Markdown.parse(@simple_note, "Test/Hello World.md")
      assert Map.has_key?(chunk, :position)
      assert Map.has_key?(chunk, :text)
      assert Map.has_key?(chunk, :context_text)
      assert Map.has_key?(chunk, :heading_path)
      assert Map.has_key?(chunk, :char_start)
      assert Map.has_key?(chunk, :char_end)
    end

    test "positions are sequential starting at 0" do
      chunks = Markdown.parse(@simple_note, "Test/Hello World.md")
      positions = Enum.map(chunks, & &1.position)
      assert positions == Enum.to_list(0..(length(chunks) - 1))
    end

    test "char offsets are non-negative and char_end > char_start" do
      chunks = Markdown.parse(@simple_note, "Test/Hello World.md")

      Enum.each(chunks, fn chunk ->
        assert chunk.char_start >= 0
        assert chunk.char_end > chunk.char_start
      end)
    end

    test "returns empty list for empty content" do
      assert Markdown.parse("", "Test/Empty.md") == []
    end

    test "returns single chunk for note with no headings" do
      content = "Just a paragraph with no headings."
      chunks = Markdown.parse(content, "Test/NoHeadings.md")
      assert length(chunks) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # heading_path extraction
  # ---------------------------------------------------------------------------

  describe "heading_path" do
    test "root section has title-only heading path" do
      chunks = Markdown.parse(@simple_note, "Test/Hello World.md")
      root = Enum.find(chunks, &(&1.position == 0))
      assert root.heading_path == "Hello World"
    end

    test "subsections include parent headings" do
      chunks = Markdown.parse(@simple_note, "Test/Hello World.md")
      section_one = Enum.find(chunks, &String.contains?(&1.text, "Content of section one"))
      assert section_one.heading_path == "Hello World > Section One"
    end

    test "nested headings build full hierarchy" do
      content = """
      # Top

      ## Middle

      ### Bottom

      Leaf content.
      """

      chunks = Markdown.parse(content, "Test/Nested.md")
      leaf = Enum.find(chunks, &String.contains?(&1.text, "Leaf content"))
      assert leaf.heading_path == "Top > Middle > Bottom"
    end
  end

  # ---------------------------------------------------------------------------
  # folder-aware context prepending
  # ---------------------------------------------------------------------------

  describe "context_text" do
    test "prepends folder when note is in a folder" do
      chunks = Markdown.parse(@simple_note, "Health/Hello World.md")
      [first | _] = chunks
      assert String.starts_with?(first.context_text, "Health > ")
    end

    test "no folder prefix for root-level notes" do
      content = "# Standalone\n\nSome text."
      chunks = Markdown.parse(content, "Standalone.md")
      [first | _] = chunks
      refute String.starts_with?(first.context_text, " > ")
      assert String.contains?(first.context_text, "Standalone")
    end

    test "context_text includes heading_path" do
      chunks = Markdown.parse(@simple_note, "Health/Hello World.md")
      section = Enum.find(chunks, &String.contains?(&1.text, "Content of section one"))
      assert String.contains?(section.context_text, "Section One")
    end

    test "context_text ends with the chunk text" do
      chunks = Markdown.parse(@simple_note, "Test/Hello World.md")

      Enum.each(chunks, fn chunk ->
        assert String.ends_with?(chunk.context_text, chunk.text)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # frontmatter handling
  # ---------------------------------------------------------------------------

  describe "frontmatter handling" do
    test "strips frontmatter from body chunk text" do
      chunks = Markdown.parse(@frontmatter_note, "Test/Tagged.md")
      body_chunks = Enum.reject(chunks, &(&1.heading_path == "frontmatter"))
      all_text = Enum.map_join(body_chunks, " ", & &1.text)
      refute String.contains?(all_text, "tags:")
      refute String.contains?(all_text, "---")
    end

    test "uses frontmatter title in heading_path" do
      chunks = Markdown.parse(@frontmatter_note, "Test/Tagged.md")
      [first | _] = chunks
      assert String.contains?(first.heading_path, "My Custom Title")
    end

    test "emits a trailing synthetic frontmatter chunk when frontmatter exists" do
      content = "---\nstatus: done\nauthor: todd\n---\n# H\n\nbody text\n"
      chunks = Markdown.parse(content, "a/n.md")

      fm = List.last(chunks)
      assert fm.heading_path == "frontmatter"
      assert fm.text =~ "status: done"
      assert fm.text =~ "author: todd"
      assert fm.char_start == 0 and fm.char_end == 0
      assert fm.position == length(chunks) - 1
    end

    test "no synthetic chunk without frontmatter" do
      chunks = Markdown.parse("# H\n\nbody\n", "a/n.md")
      refute Enum.any?(chunks, &(&1.heading_path == "frontmatter"))
    end

    test "frontmatter-only note yields just the frontmatter chunk" do
      chunks = Markdown.parse("---\nstatus: done\n---\n", "a/n.md")
      assert [%{heading_path: "frontmatter"}] = chunks
    end

    # #1605: the strip measured the frontmatter in BYTES and sliced the note
    # in GRAPHEMES, so every multibyte character cut one more from the body.
    test "multibyte frontmatter keeps the whole body" do
      content = "---\ntitle: 日本語のノート\n---\nHello world this is the body."
      [body | _] = Markdown.parse(content, "a/n.md")
      assert body.text == "Hello world this is the body."
    end

    test "CRLF frontmatter keeps the whole body and still emits the frontmatter chunk" do
      content = "---\r\ntitle: T\r\n---\r\nHello world this is the body.\r\n"
      chunks = Markdown.parse(content, "a/n.md")

      [body | _] = chunks
      assert body.text == "Hello world this is the body."
      assert %{text: "title: T\n"} = List.last(chunks)
    end

    test "a closing fence at EOF is indexed once, as the frontmatter chunk" do
      chunks = Markdown.parse("---\nstatus: done\n---", "a/n.md")
      assert [%{heading_path: "frontmatter"}] = chunks
    end
  end

  # ---------------------------------------------------------------------------
  # large content sub-chunking
  # ---------------------------------------------------------------------------

  describe "sub-chunking" do
    test "splits very long sections into multiple chunks" do
      # Generate ~3000 chars — roughly 750 tokens, above 512 threshold
      long_section = String.duplicate("word ", 600)
      content = "# Long\n\n" <> long_section

      chunks = Markdown.parse(content, "Test/Long.md")
      assert length(chunks) > 1
    end

    test "sub-chunks share the same heading_path" do
      long_section = String.duplicate("word ", 600)
      content = "# Long\n\n" <> long_section

      chunks = Markdown.parse(content, "Test/Long.md")
      heading_paths = Enum.map(chunks, & &1.heading_path) |> Enum.uniq()
      assert length(heading_paths) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Hard size cap
  #
  # Every chunk's text is embedded by Voyage, which rejects an oversized input
  # with a permanent HTTP 400 — no retry fixes it, so the note is parked on a
  # 6h poison cooldown and re-tried forever (prod, 2026-09-09). The word-boundary
  # splitter is best-effort; these cases have no word boundary to split on, so
  # the cap has to hold regardless of the input's shape.
  # ---------------------------------------------------------------------------

  describe "chunk size cap" do
    @max_chunk_chars 2048

    defp assert_all_capped(chunks) do
      refute chunks == []

      for chunk <- chunks do
        assert byte_size(chunk.text) <= @max_chunk_chars,
               "chunk text is #{byte_size(chunk.text)} bytes, over the #{@max_chunk_chars} cap"

        assert String.valid?(chunk.text), "chunk text was split mid-codepoint"
      end
    end

    test "caps a space-free run (base64 data URI, long URL, minified blob)" do
      blob = String.duplicate("A", 60_000)

      "# Title\n\n![img](data:image/png;base64,#{blob})\n"
      |> Markdown.parse("Test/Blob.md")
      |> assert_all_capped()
    end

    test "caps an oversized frontmatter block" do
      ("---\nnote: " <> String.duplicate("x y ", 30_000) <> "\n---\n\n# T\n\nbody\n")
      |> Markdown.parse("Test/Frontmatter.md")
      |> assert_all_capped()
    end

    test "caps space-free multibyte text without splitting mid-codepoint" do
      # CJK has no spaces to split on, and each char is 3 bytes — a
      # grapheme-counted cap would overshoot the byte budget ~3x.
      ("# 見出し\n\n" <> String.duplicate("日本語", 20_000))
      |> Markdown.parse("Test/CJK.md")
      |> assert_all_capped()
    end

    # Scoped to a body with no spaces, so the word splitter has no boundary to
    # drop — packing at word boundaries is lossy by design (it collapses the
    # space it split on), and that predates the cap. What must not lose or
    # duplicate a byte is the hard split itself.
    # The heading line stays in the chunk text on purpose — the BM25 leg indexes
    # `text`, not `context_text`, so stripping it would make headings invisible
    # to keyword search. What must not happen is the packer flushing it alone:
    # a bare "#" embeds to a meaningless vector and still costs a Qdrant point.
    test "a heading before an oversized run does not leave a runt chunk" do
      for body <- [
            String.duplicate("A", 10_000),
            "https://x.example/" <> String.duplicate("a", 5_000)
          ] do
        chunks = Markdown.parse("# Heading\n\n" <> body, "Test/Runt.md")

        assert length(chunks) > 1

        refute Enum.any?(chunks, &(byte_size(&1.text) < 20)),
               "runt chunks: #{inspect(Enum.filter(chunks, &(byte_size(&1.text) < 20)) |> Enum.map(& &1.text))}"
      end
    end

    test "hard split preserves every byte of a space-free body" do
      for body <- [String.duplicate("A", 10_000), String.duplicate("日本語", 5_000)] do
        chunks = Markdown.parse(body, "Test/Blob.md")

        assert length(chunks) > 1
        assert Enum.map_join(chunks, & &1.text) == body
      end
    end
  end
end
