defmodule Engram.MCP.SectionsTest do
  use ExUnit.Case, async: true

  alias Engram.MCP.Sections

  # Built with String.duplicate so this file never holds a literal fence.
  @bt String.duplicate("`", 3)
  @note Enum.join(
          [
            "---",
            "title: T",
            "# yaml comment, not a heading",
            "---",
            "# Title",
            "",
            "## Todo",
            "",
            "a",
            "",
            @bt <> "sh",
            "# shell comment, not a heading",
            "## also not",
            @bt,
            "",
            "### Sub",
            "",
            "s",
            "",
            "## Done",
            "",
            "x",
            ""
          ],
          "\n"
        )

  test "headings skip frontmatter and fenced code" do
    assert Enum.map(Sections.headings(@note), &{&1.level, &1.text}) ==
             [{1, "Title"}, {2, "Todo"}, {3, "Sub"}, {2, "Done"}]
  end

  test "tilde fences and unclosed fences hide headings too" do
    assert Sections.headings("## A\n~~~\n## B\n~~~\n## C") |> Enum.map(& &1.text) == ["A", "C"]
    assert Sections.headings("## A\n" <> @bt <> "\n## B") |> Enum.map(& &1.text) == ["A"]
  end

  test "hashtags, 7 hashes and CRLF" do
    assert Sections.headings("#tag\n####### x\n## A\r\nbody\r\n") |> Enum.map(& &1.text) == ["A"]
  end

  test "find spans nested subsections and stops at the next same-or-higher heading" do
    assert {:ok, %{start: s, stop: e}} = Sections.find(@note, "Todo", 2)
    lines = String.split(@note, "\n")
    assert Enum.at(lines, s) == "## Todo"
    assert Enum.at(lines, e) == "## Done"
  end

  test "find respects level, and never matches inside a fence" do
    assert Sections.find(@note, "Todo", 3) == :error
    assert Sections.find(@note, "also not", 2) == :error
    assert Sections.find(@note, "yaml comment, not a heading", 1) == :error
  end

  test "section returns the heading and its body, fenced # lines included" do
    assert {:ok, text} = Sections.section(@note, "Todo")
    assert text =~ ~r/\A## Todo\n/
    assert text =~ "# shell comment, not a heading"
    assert text =~ "### Sub\n\ns"
    refute text =~ "## Done"
    assert Sections.section(@note, "Nope") == :error
  end

  test "insert start goes directly under the heading line" do
    assert {:ok, out} = Sections.insert(@note, "Todo", 2, "start", "NEW\n")
    assert out =~ "## Todo\nNEW\n\na"
  end

  # Review Focus 1 (nested subheadings) and 5 (fence inside the section)
  test "insert end goes after the last subsection line, before the next same-level heading" do
    assert {:ok, out} = Sections.insert(@note, "Todo", 2, "end", "NEW")
    assert out =~ "### Sub\n\ns\nNEW\n\n## Done"
  end

  # Review Focus 1 (last section)
  test "insert end on the last section keeps the trailing newline" do
    assert {:ok, out} = Sections.insert(@note, "Done", 2, "end", "y")
    assert String.ends_with?(out, "## Done\n\nx\ny\n")
  end

  test "insert on a missing heading is :error" do
    assert Sections.insert(@note, "Nope", 2, "end", "y") == :error
  end

  # Fix round 1, finding 1: CommonMark allows at most 3 leading spaces on an
  # ATX heading; 4+ is an indented code line, not a heading, and must not end
  # a section either.
  test "a line indented 4+ spaces is not a heading, and does not end a section" do
    content = "## Todo\n\na\n    ## not a heading\nb\n\n## Done\n\nx\n"

    assert Sections.headings(content) |> Enum.map(&{&1.level, &1.text}) ==
             [{2, "Todo"}, {2, "Done"}]

    assert {:ok, text} = Sections.section(content, "Todo")
    assert text =~ "    ## not a heading"
    assert text =~ "b"
    refute text =~ "## Done"
  end

  # Fix round 1, finding 2: an ATX heading may end with an optional closing
  # sequence of #s, which must be preceded by a space and stripped along with
  # any trailing whitespace.
  test "an ATX closing sequence of #s is stripped from the heading text" do
    assert Sections.headings("## Title ##") |> Enum.map(& &1.text) == ["Title"]
    assert Sections.headings("## Title #") |> Enum.map(& &1.text) == ["Title"]
  end

  # Fix round 1, finding 3: `\s+` after the hashes matches any run of
  # whitespace, not just a single space, so extra spaces before the heading
  # text are tolerated. Deliberate improvement over the old exact-string match.
  test "extra whitespace between the hashes and the heading text is tolerated" do
    assert Sections.headings("##  Todo") |> Enum.map(& &1.text) == ["Todo"]
  end

  # Review round 2, finding 1: a closing fence may not carry an info string.
  # "```elixir" inside an already-open fence is still code, not a closer.
  test "a closing fence must not carry an info string" do
    content = @bt <> "\n" <> @bt <> "elixir\n# X\n" <> @bt <> "\n# Y"
    assert Sections.headings(content) |> Enum.map(& &1.text) == ["Y"]
  end

  # Review round 2, finding 2: CommonMark forbids a backtick in a backtick
  # fence's info string (ambiguous with inline code spans), so this line
  # never opens a fence at all.
  test "a backtick fence opener with a backtick in its info string is not a fence" do
    assert Sections.headings("#{@bt} a`b\n# X") |> Enum.map(& &1.text) == ["X"]
  end

  # Review round 2, finding 3: inserting into a CRLF note must not leave a
  # mix of bare \n and \r\n line endings behind.
  test "insert converts inserted text to CRLF when the note uses CRLF" do
    assert {:ok, out} = Sections.insert("## A\r\nx\r\n", "A", 2, "start", "n1\nn2")
    assert out == "## A\r\nn1\r\nn2\r\nx\r\n"
  end

  test "insert leaves LF-only notes alone" do
    assert {:ok, out} = Sections.insert("## A\nx\n", "A", 2, "start", "n1\nn2")
    assert out == "## A\nn1\nn2\nx\n"
  end

  # Review round 2, finding 4: setext headings (a paragraph line underlined
  # with =/- ) must be recognized like ATX headings.
  test "a setext heading is recognized, with text on the paragraph line" do
    content = "Title\n=====\n\nbody\n\nSubtitle\n--------\n\nmore\n"

    assert Sections.headings(content) |> Enum.map(&{&1.level, &1.text}) ==
             [{1, "Title"}, {2, "Subtitle"}]
  end

  test "a setext heading's line is the text line, not the underline" do
    content = "Title\n=====\nbody\n"
    assert {:ok, %{start: 0}} = Sections.find(content, "Title", 1)
  end

  test "a thematic break after a blank line is not a setext heading" do
    assert Sections.headings("para\n\n---\nmore\n") == []
  end

  test "a list item line is not a setext underline" do
    assert Sections.headings("para\n- item\n") == []
  end

  test "an underline inside a fence is not a setext heading" do
    content = @bt <> "\npara\n---\n" <> @bt <> "\n"
    assert Sections.headings(content) == []
  end

  test "a setext underline right after an ATX heading is not setext" do
    assert Sections.headings("## Real\n---\nmore\n") |> Enum.map(&{&1.level, &1.text}) ==
             [{2, "Real"}]
  end

  test "a setext underline right after a fence close is not setext" do
    content = "para\n" <> @bt <> "\n" <> @bt <> "\n---\nmore\n"
    assert Sections.headings(content) == []
  end

  test "section on a setext heading includes both heading lines and stops before the next same-level heading" do
    content = "Title\n=====\n\nbody\n\nNext\n====\n\nz\n"
    assert {:ok, text} = Sections.section(content, "Title")
    assert text == "Title\n=====\n\nbody"
  end

  test "insert start on a setext heading lands after the underline" do
    content = "Title\n=====\nbody\n"
    assert {:ok, out} = Sections.insert(content, "Title", 1, "start", "new")
    assert out == "Title\n=====\nnew\nbody\n"
  end

  # Review round 2, finding 5: a UTF-8 BOM at the start of the file must not
  # hide a heading on line 0, and the tab-indent rule must match CommonMark's
  # column counting, not character counting.
  test "a UTF-8 BOM at the start of the file does not hide the first heading" do
    content = "﻿# Title\n\nbody\n"
    assert Sections.headings(content) |> Enum.map(&{&1.line, &1.text}) == [{0, "Title"}]
  end

  test "a UTF-8 BOM does not shift line numbers, and insert keeps the BOM in the output" do
    content = "﻿# Title\n\nbody\n"
    assert {:ok, out} = Sections.insert(content, "Title", 1, "start", "new")
    assert String.starts_with?(out, "﻿# Title\nnew\n")
  end

  test "a tab-indented heading line is code, not a heading" do
    assert Sections.headings("\t# X") == []
  end
end
