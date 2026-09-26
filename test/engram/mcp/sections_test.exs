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
end
