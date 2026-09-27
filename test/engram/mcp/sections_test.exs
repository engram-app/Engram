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

  # Fix round 2, Important: only a line that could be paragraph text can
  # start/continue a setext paragraph. A list item, blockquote, indented
  # code, or HTML block line followed by a dash/equals run is a thematic
  # break (or plain content), never a setext heading.
  test "a dash list item does not start a setext paragraph" do
    assert Sections.headings("- item\n---") == []
  end

  test "a dash list item is not confused with a level-1 setext underline either" do
    assert Sections.headings("- item\n===") == []
  end

  test "an ordered list item with a dot marker does not start a setext paragraph" do
    assert Sections.headings("1. item\n---") == []
  end

  test "an ordered list item with a paren marker does not start a setext paragraph" do
    assert Sections.headings("2) item\n---") == []
  end

  test "a star list item does not start a setext paragraph" do
    assert Sections.headings("* item\n---") == []
  end

  test "a plus list item does not start a setext paragraph" do
    assert Sections.headings("+ item\n---") == []
  end

  test "a blockquote line does not start a setext paragraph" do
    assert Sections.headings("> q\n---") == []
  end

  test "a multi-line blockquote does not start a setext paragraph" do
    assert Sections.headings("> [!note] T\n> body\n---") == []
  end

  test "a 4-space indented code line does not start a setext paragraph" do
    assert Sections.headings("    code\n---") == []
  end

  test "a tab-indented code line does not start a setext paragraph" do
    assert Sections.headings("\tcode\n---") == []
  end

  test "an HTML block does not start or continue a setext paragraph" do
    assert Sections.headings("<div>\nhi\n</div>\n---") == []
  end

  test "an HTML comment block does not start or continue a setext paragraph" do
    assert Sections.headings("<!--\nfoo\n-->\n---") == []
  end

  test "headings does not list a list item as a heading, even with a following thematic break" do
    content = "## A\n- item\n---\n## B\nb\n"
    assert Sections.headings(content) |> Enum.map(&{&1.level, &1.text}) == [{2, "A"}, {2, "B"}]
  end

  # Fix round 2, Minor 1: a multi-line paragraph immediately before an
  # underline is ALL setext heading text, not just its last line.
  test "a multi-line paragraph before an underline becomes one heading, text joined with spaces" do
    content = "a\nb\n===\nx"

    assert Sections.headings(content) |> Enum.map(&{&1.line, &1.level, &1.text}) ==
             [{0, 1, "a b"}]
  end

  test "section on a multi-line setext heading includes every paragraph line plus the underline" do
    content = "para1\npara2\n---\nbody"
    assert {:ok, text} = Sections.section(content, "para1 para2")
    assert text == content
  end

  test "the old single-line reading of a multi-line setext heading no longer matches" do
    assert Sections.find("a\nb\n===\nx", "b", 1) == :error
  end

  # Fix round 2, Minor 2: the BOM must be stripped before frontmatter
  # detection too, not just before the heading scan.
  test "a BOM before frontmatter does not defeat frontmatter skipping" do
    content = "﻿---\ntitle: x\n---\n# X"
    assert Sections.headings(content) |> Enum.map(& &1.text) == ["X"]
  end

  # Fix round 2, Minor 3: appending to a CRLF note with no trailing newline
  # must not leave a bare LF or a stray trailing CR.
  test "insert end on a CRLF note with no trailing newline stays uniform" do
    assert {:ok, out} = Sections.insert("## A\r\nx", "A", 2, "end", "n1")
    assert out == "## A\r\nx\r\nn1"
    refute out =~ ~r/[^\r]\n/
    refute String.ends_with?(out, "\r")
  end

  # Regressions to keep green: ATX closing #s (already covered above), a
  # spaced dash run is a thematic break not setext, a GFM table delimiter row
  # is not setext, an indented dash run is not setext, and setext still works
  # on a CRLF note.
  test "a spaced dash run is not a setext underline" do
    assert Sections.headings("para\n- - -\nmore\n") == []
  end

  test "a GFM table delimiter row is not a setext underline" do
    content = "Col1 | Col2\n--- | ---\ndata | data\n"
    assert Sections.headings(content) == []
  end

  test "an indented dash run is not a setext underline" do
    assert Sections.headings("foo\n    ---\n") == []
  end

  test "a setext heading is recognized in a CRLF note" do
    content = "Title\r\n=====\r\nbody\r\n"
    assert Sections.headings(content) |> Enum.map(&{&1.level, &1.text}) == [{1, "Title"}]
  end

  # Fix round 3, finding 1: match_eol must stay LOCAL to the edit. A note
  # that mixes a CRLF line with LF lines elsewhere must not have its
  # untouched lines rewritten just because the whole file "contains \r\n"
  # somewhere.
  test "insert only touches the inserted fragment, not lines outside the edit" do
    content = "## A\r\nx\n## B\ny"
    assert {:ok, out} = Sections.insert(content, "A", 2, "start", "n1")
    assert out == "## A\r\nn1\r\nx\n## B\ny"
    assert String.ends_with?(out, "x\n## B\ny")
  end

  # Fix round 3, finding 2: CommonMark's paragraph-INTERRUPT rules are
  # narrower than its block-START rules. "<" only blocks a setext paragraph
  # when it opens an actual HTML block (script/pre/style/textarea, a
  # comment, a processing instruction, a declaration, CDATA, or a
  # block-level tag) -- inline HTML and autolinks are just paragraph text.
  test "an autolink does not block a setext paragraph" do
    content = "<https://x.com> rocks\n---"

    assert Sections.headings(content) |> Enum.map(&{&1.level, &1.text}) ==
             [{2, "<https://x.com> rocks"}]
  end

  test "inline HTML does not block a setext paragraph" do
    content = "<b>bold</b> x\n---"
    assert Sections.headings(content) |> Enum.map(&{&1.level, &1.text}) == [{2, "<b>bold</b> x"}]
  end

  test "inline HTML on a continuation line does not block a setext paragraph" do
    content = "x\n<b>inline</b>\n---"

    assert Sections.headings(content) |> Enum.map(&{&1.level, &1.text}) ==
             [{2, "x <b>inline</b>"}]
  end

  test "a script tag opening line blocks a setext paragraph (real HTML block, type 1)" do
    assert Sections.headings("<script>\n---") == []
  end

  # A 4+ indent only matters for the FIRST line of a paragraph; on a
  # continuation line it's a lazy continuation, still paragraph text.
  test "a 4-space indented continuation line is a lazy continuation, not code" do
    content = "p\n    indented cont\n==="

    assert Sections.headings(content) |> Enum.map(&{&1.line, &1.level, &1.text}) ==
             [{0, 1, "p indented cont"}]
  end

  # An ordered list only interrupts a paragraph when it starts at 1; any
  # other start number is lazy continuation text instead.
  test "an ordered list not starting at 1 does not interrupt a paragraph" do
    content = "a\n2. b\n---"
    assert Sections.headings(content) |> Enum.map(&{&1.level, &1.text}) == [{2, "a 2. b"}]
  end

  test "an ordered list starting at 1 does interrupt a paragraph" do
    assert Sections.headings("a\n1. b\n---") == []
  end

  test "an empty bullet item does not start a setext paragraph" do
    assert Sections.headings("*\n---") == []
  end

  test "an empty ordered item does not start a setext paragraph" do
    assert Sections.headings("1.\n---") == []
  end

  # Fix round 3, finding 3: Obsidian %% comments hide headings the same way
  # <!-- --> does.
  test "an Obsidian %% comment block hides a heading inside it" do
    content = "%%\n# H\n%%\n# Real"
    assert Sections.headings(content) |> Enum.map(&{&1.level, &1.text}) == [{1, "Real"}]
  end

  test "a single-line Obsidian %% comment does not affect later lines" do
    content = "%% note %%\n# Real"
    assert Sections.headings(content) |> Enum.map(&{&1.level, &1.text}) == [{1, "Real"}]
  end

  test "an unclosed Obsidian %% comment hides everything after it" do
    assert Sections.headings("%%\n# H") == []
  end

  # Fix round 4 (final): a "%%" (or "<!--"/"-->") inside an inline code span
  # is literal text in Obsidian, not a comment delimiter. Repro: this used to
  # find only heading A (the %% in the code span "opened" a comment that
  # swallowed B to EOF).
  test "a %% inside a code span does not open a comment" do
    content = "## A\nUse `%%` to hide text in Obsidian.\n\n## B\nkeep me\n"
    assert Sections.headings(content) |> Enum.map(&{&1.level, &1.text}) == [{2, "A"}, {2, "B"}]

    assert {:ok, %{stop: stop}} = Sections.find(content, "A", 2)
    lines = String.split(content, "\n")
    assert Enum.at(lines, stop) == "## B"
  end

  test "printf-style %% inside a code span does not open a comment" do
    content = "## A\n`printf(\"100%%\")`\n\n## B\nkeep\n"
    assert Sections.headings(content) |> Enum.map(&{&1.level, &1.text}) == [{2, "A"}, {2, "B"}]
  end

  test "a SQL LIKE '%%' inside a code span does not open a comment" do
    content = "## A\n`LIKE '%%'`\n\n## B\nkeep\n"
    assert Sections.headings(content) |> Enum.map(&{&1.level, &1.text}) == [{2, "A"}, {2, "B"}]
  end

  test "<!-- inside a code span does not open an HTML comment" do
    content = "## A\nUse `<!--` to start a comment.\n\n## B\nkeep\n"
    assert Sections.headings(content) |> Enum.map(&{&1.level, &1.text}) == [{2, "A"}, {2, "B"}]
  end

  # Fix round 4, defense in depth: a GENUINE unclosed comment must not let
  # replace_section/insert_section(end) silently delete or misplace content
  # past it -- find/3 flags it instead of quietly reporting stop == EOF.
  test "find flags a section whose stop is EOF because of a genuine unclosed comment" do
    content = "## A\n%%\nunclosed\n\n## B\nkeep\n"
    assert {:ok, %{unclosed_comment_at: line}} = Sections.find(content, "A", 2)
    assert line == 1
  end

  test "find does not flag a section whose stop is a real next heading" do
    content = "## A\nx\n\n## B\nkeep\n"
    assert {:ok, %{unclosed_comment_at: nil}} = Sections.find(content, "A", 2)
  end

  test "find does not flag a section that legitimately runs to EOF with no comment involved" do
    content = "## A\nx\n"
    assert {:ok, %{unclosed_comment_at: nil}} = Sections.find(content, "A", 2)
  end

  test "insert position end into a section with a genuine unclosed comment refuses" do
    content = "## A\n%%\nunclosed\n\n## B\nkeep\n"
    assert Sections.insert(content, "A", 2, "end", "n1") == {:error, {:unclosed_comment, 1}}
  end

  test "insert position start is unaffected by a genuine unclosed comment further down" do
    content = "## A\n%%\nunclosed\n\n## B\nkeep\n"
    assert {:ok, out} = Sections.insert(content, "A", 2, "start", "n1")
    assert out =~ "## A\nn1\n%%"
  end
end
