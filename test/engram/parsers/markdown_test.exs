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
    test "strips frontmatter from chunk text" do
      chunks = Markdown.parse(@frontmatter_note, "Test/Tagged.md")
      all_text = Enum.map_join(chunks, " ", & &1.text)
      refute String.contains?(all_text, "tags:")
      refute String.contains?(all_text, "---")
    end

    test "uses frontmatter title in heading_path" do
      chunks = Markdown.parse(@frontmatter_note, "Test/Tagged.md")
      [first | _] = chunks
      assert String.contains?(first.heading_path, "My Custom Title")
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
end
