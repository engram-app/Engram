defmodule Engram.MCP.SectionsTest do
  use ExUnit.Case, async: true

  alias Engram.MCP.Sections

  defp headings!(content) do
    assert {:ok, hs} = Sections.headings(content)
    hs
  end

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
    assert Enum.map(headings!(@note), &{&1.level, &1.text}) ==
             [{1, "Title"}, {2, "Todo"}, {3, "Sub"}, {2, "Done"}]
  end

  test "tilde fences and unclosed fences hide headings too" do
    assert headings!("## A\n~~~\n## B\n~~~\n## C") |> Enum.map(& &1.text) == ["A", "C"]
    assert headings!("## A\n" <> @bt <> "\n## B") |> Enum.map(& &1.text) == ["A"]
  end

  test "hashtags, 7 hashes and CRLF" do
    assert headings!("#tag\n####### x\n## A\r\nbody\r\n") |> Enum.map(& &1.text) == ["A"]
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
    assert {:error, {:not_found, [_ | _]}} = Sections.section(@note, "Nope")
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

    assert headings!(content) |> Enum.map(&{&1.level, &1.text}) ==
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
    assert headings!("## Title ##") |> Enum.map(& &1.text) == ["Title"]
    assert headings!("## Title #") |> Enum.map(& &1.text) == ["Title"]
  end

  # Fix round 1, finding 3: `\s+` after the hashes matches any run of
  # whitespace, not just a single space, so extra spaces before the heading
  # text are tolerated. Deliberate improvement over the old exact-string match.
  test "extra whitespace between the hashes and the heading text is tolerated" do
    assert headings!("##  Todo") |> Enum.map(& &1.text) == ["Todo"]
  end

  # Review round 2, finding 1: a closing fence may not carry an info string.
  # "```elixir" inside an already-open fence is still code, not a closer.
  test "a closing fence must not carry an info string" do
    content = @bt <> "\n" <> @bt <> "elixir\n# X\n" <> @bt <> "\n# Y"
    assert headings!(content) |> Enum.map(& &1.text) == ["Y"]
  end

  # Review round 2, finding 2: CommonMark forbids a backtick in a backtick
  # fence's info string (ambiguous with inline code spans), so this line
  # never opens a fence at all.
  test "a backtick fence opener with a backtick in its info string is not a fence" do
    assert headings!("#{@bt} a`b\n# X") |> Enum.map(& &1.text) == ["X"]
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

    assert headings!(content) |> Enum.map(&{&1.level, &1.text}) ==
             [{1, "Title"}, {2, "Subtitle"}]
  end

  test "a setext heading's line is the text line, not the underline" do
    content = "Title\n=====\nbody\n"
    assert {:ok, %{start: 0}} = Sections.find(content, "Title", 1)
  end

  test "a thematic break after a blank line is not a setext heading" do
    assert headings!("para\n\n---\nmore\n") == []
  end

  test "a list item line is not a setext underline" do
    assert headings!("para\n- item\n") == []
  end

  test "an underline inside a fence is not a setext heading" do
    content = @bt <> "\npara\n---\n" <> @bt <> "\n"
    assert headings!(content) == []
  end

  test "a setext underline right after an ATX heading is not setext" do
    assert headings!("## Real\n---\nmore\n") |> Enum.map(&{&1.level, &1.text}) ==
             [{2, "Real"}]
  end

  test "a setext underline right after a fence close is not setext" do
    content = "para\n" <> @bt <> "\n" <> @bt <> "\n---\nmore\n"
    assert headings!(content) == []
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
    assert headings!(content) |> Enum.map(&{&1.line, &1.text}) == [{0, "Title"}]
  end

  test "a UTF-8 BOM does not shift line numbers, and insert keeps the BOM in the output" do
    content = "﻿# Title\n\nbody\n"
    assert {:ok, out} = Sections.insert(content, "Title", 1, "start", "new")
    assert String.starts_with?(out, "﻿# Title\nnew\n")
  end

  test "a tab-indented heading line is code, not a heading" do
    assert headings!("\t# X") == []
  end

  # Fix round 2, Important: only a line that could be paragraph text can
  # start/continue a setext paragraph. A list item, blockquote, indented
  # code, or HTML block line followed by a dash/equals run is a thematic
  # break (or plain content), never a setext heading.
  test "a dash list item does not start a setext paragraph" do
    assert headings!("- item\n---") == []
  end

  test "a dash list item is not confused with a level-1 setext underline either" do
    assert headings!("- item\n===") == []
  end

  test "an ordered list item with a dot marker does not start a setext paragraph" do
    assert headings!("1. item\n---") == []
  end

  test "an ordered list item with a paren marker does not start a setext paragraph" do
    assert headings!("2) item\n---") == []
  end

  test "a star list item does not start a setext paragraph" do
    assert headings!("* item\n---") == []
  end

  test "a plus list item does not start a setext paragraph" do
    assert headings!("+ item\n---") == []
  end

  test "a blockquote line does not start a setext paragraph" do
    assert headings!("> q\n---") == []
  end

  test "a multi-line blockquote does not start a setext paragraph" do
    assert headings!("> [!note] T\n> body\n---") == []
  end

  test "a 4-space indented code line does not start a setext paragraph" do
    assert headings!("    code\n---") == []
  end

  test "a tab-indented code line does not start a setext paragraph" do
    assert headings!("\tcode\n---") == []
  end

  test "an HTML block does not start or continue a setext paragraph" do
    assert headings!("<div>\nhi\n</div>\n---") == []
  end

  test "an HTML comment block does not start or continue a setext paragraph" do
    assert headings!("<!--\nfoo\n-->\n---") == []
  end

  test "headings does not list a list item as a heading, even with a following thematic break" do
    content = "## A\n- item\n---\n## B\nb\n"
    assert headings!(content) |> Enum.map(&{&1.level, &1.text}) == [{2, "A"}, {2, "B"}]
  end

  # Fix round 2, Minor 1: a multi-line paragraph immediately before an
  # underline is ALL setext heading text, not just its last line.
  test "a multi-line paragraph before an underline becomes one heading, text joined with spaces" do
    content = "a\nb\n===\nx"

    assert headings!(content) |> Enum.map(&{&1.line, &1.level, &1.text}) ==
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
    assert headings!(content) |> Enum.map(& &1.text) == ["X"]
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
    assert headings!("para\n- - -\nmore\n") == []
  end

  test "a GFM table delimiter row is not a setext underline" do
    content = "Col1 | Col2\n--- | ---\ndata | data\n"
    assert headings!(content) == []
  end

  test "an indented dash run is not a setext underline" do
    assert headings!("foo\n    ---\n") == []
  end

  test "a setext heading is recognized in a CRLF note" do
    content = "Title\r\n=====\r\nbody\r\n"
    assert headings!(content) |> Enum.map(&{&1.level, &1.text}) == [{1, "Title"}]
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
  # Heading text is the RENDERED inline text (CommonMark parser): an
  # autolink renders as its URL, without the angle brackets.
  test "an autolink does not block a setext paragraph" do
    content = "<https://x.com> rocks\n---"

    assert headings!(content) |> Enum.map(&{&1.level, &1.text}) ==
             [{2, "https://x.com rocks"}]
  end

  test "inline HTML does not block a setext paragraph" do
    content = "<b>bold</b> x\n---"
    assert headings!(content) |> Enum.map(&{&1.level, &1.text}) == [{2, "<b>bold</b> x"}]
  end

  test "inline HTML on a continuation line does not block a setext paragraph" do
    content = "x\n<b>inline</b>\n---"

    assert headings!(content) |> Enum.map(&{&1.level, &1.text}) ==
             [{2, "x <b>inline</b>"}]
  end

  test "a script tag opening line blocks a setext paragraph (real HTML block, type 1)" do
    assert headings!("<script>\n---") == []
  end

  # A 4+ indent only matters for the FIRST line of a paragraph; on a
  # continuation line it's a lazy continuation, still paragraph text.
  test "a 4-space indented continuation line is a lazy continuation, not code" do
    content = "p\n    indented cont\n==="

    assert headings!(content) |> Enum.map(&{&1.line, &1.level, &1.text}) ==
             [{0, 1, "p indented cont"}]
  end

  # An ordered list only interrupts a paragraph when it starts at 1; any
  # other start number is lazy continuation text instead.
  test "an ordered list not starting at 1 does not interrupt a paragraph" do
    content = "a\n2. b\n---"
    assert headings!(content) |> Enum.map(&{&1.level, &1.text}) == [{2, "a 2. b"}]
  end

  test "an ordered list starting at 1 does interrupt a paragraph" do
    assert headings!("a\n1. b\n---") == []
  end

  test "an empty bullet item does not start a setext paragraph" do
    assert headings!("*\n---") == []
  end

  test "an empty ordered item does not start a setext paragraph" do
    assert headings!("1.\n---") == []
  end

  # Fix round 3, finding 3: Obsidian %% comments hide headings the same way
  # <!-- --> does.
  test "an Obsidian %% comment block hides a heading inside it" do
    content = "%%\n# H\n%%\n# Real"
    assert headings!(content) |> Enum.map(&{&1.level, &1.text}) == [{1, "Real"}]
  end

  test "a single-line Obsidian %% comment does not affect later lines" do
    content = "%% note %%\n# Real"
    assert headings!(content) |> Enum.map(&{&1.level, &1.text}) == [{1, "Real"}]
  end

  test "an unclosed Obsidian %% comment hides everything after it" do
    assert headings!("%%\n# H") == []
  end

  # Fix round 4 (final): a "%%" (or "<!--"/"-->") inside an inline code span
  # is literal text in Obsidian, not a comment delimiter. Repro: this used to
  # find only heading A (the %% in the code span "opened" a comment that
  # swallowed B to EOF).
  test "a %% inside a code span does not open a comment" do
    content = "## A\nUse `%%` to hide text in Obsidian.\n\n## B\nkeep me\n"
    assert headings!(content) |> Enum.map(&{&1.level, &1.text}) == [{2, "A"}, {2, "B"}]

    assert {:ok, %{stop: stop}} = Sections.find(content, "A", 2)
    lines = String.split(content, "\n")
    assert Enum.at(lines, stop) == "## B"
  end

  test "printf-style %% inside a code span does not open a comment" do
    content = "## A\n`printf(\"100%%\")`\n\n## B\nkeep\n"
    assert headings!(content) |> Enum.map(&{&1.level, &1.text}) == [{2, "A"}, {2, "B"}]
  end

  test "a SQL LIKE '%%' inside a code span does not open a comment" do
    content = "## A\n`LIKE '%%'`\n\n## B\nkeep\n"
    assert headings!(content) |> Enum.map(&{&1.level, &1.text}) == [{2, "A"}, {2, "B"}]
  end

  test "<!-- inside a code span does not open an HTML comment" do
    content = "## A\nUse `<!--` to start a comment.\n\n## B\nkeep\n"
    assert headings!(content) |> Enum.map(&{&1.level, &1.text}) == [{2, "A"}, {2, "B"}]
  end

  # Fix round 4, defense in depth: a GENUINE unclosed comment must not let
  # replace_section/insert_section(end) silently delete or misplace content
  # past it -- find/3 flags it instead of quietly reporting stop == EOF.
  test "find flags a section whose stop is EOF because of a genuine unclosed comment" do
    content = "## A\n%%\nunclosed\n\n## B\nkeep\n"
    assert {:ok, %{hidden_heading_at: line}} = Sections.find(content, "A", 2)
    assert line == 4
  end

  test "find does not flag a section whose stop is a real next heading" do
    content = "## A\nx\n\n## B\nkeep\n"
    assert {:ok, %{hidden_heading_at: nil}} = Sections.find(content, "A", 2)
  end

  test "find does not flag a section that legitimately runs to EOF with no comment involved" do
    content = "## A\nx\n"
    assert {:ok, %{hidden_heading_at: nil}} = Sections.find(content, "A", 2)
  end

  test "insert position end into a section with a genuine unclosed comment refuses" do
    content = "## A\n%%\nunclosed\n\n## B\nkeep\n"
    assert Sections.insert(content, "A", 2, "end", "n1") == {:error, {:hidden_heading, 4}}
  end

  test "insert position start is unaffected by a genuine unclosed comment further down" do
    content = "## A\n%%\nunclosed\n\n## B\nkeep\n"
    assert {:ok, out} = Sections.insert(content, "A", 2, "start", "n1")
    assert out =~ "## A\nn1\n%%"
  end

  # --- CommonMark parser (MDEx) regressions: review findings C1, I1, I2, I3 ---

  defp lt(content), do: headings!(content) |> Enum.map(&{&1.line, &1.text})

  # C1: HTML comment content is not markdown, so a "-->" inside what looks
  # like a code span still closes the comment.
  test "a --> inside backticks closes an open HTML comment" do
    content = "## A\nbody\n<!--\na `-->` b\n## B\nimportant\n<!-- c -->\n"
    assert lt(content) == [{0, "A"}, {4, "B"}]
    assert {:ok, %{stop: 4, hidden_heading_at: nil}} = Sections.find(content, "A", 2)
  end

  # I1: a fence closer indented past the list item's content column still
  # closes the fence (up to 3 spaces relative to the content column).
  test "a fence closer indented relative to a list item's content column closes the fence" do
    content = "## A\n1. step\n   #{@bt}bash\n   run\n    #{@bt}\n## B\nimportant\n"
    assert lt(content) == [{0, "A"}, {5, "B"}]
    assert {:ok, %{stop: 5}} = Sections.find(content, "A", 2)
  end

  # I1, second variant: a column-0 fence under a list item's fence is NOT its
  # closer; it ends the list and opens a new top-level fence that never
  # closes, so "## B" really is code (CommonMark). The section A then only
  # reaches EOF because of that unclosed fence, so a write must refuse.
  test "a column-0 fence under a list item's fence opens a new unclosed fence" do
    content = "## A\n1. step\n   #{@bt}bash\n   run\n#{@bt}\n## B\nimportant\n"
    assert lt(content) == [{0, "A"}]

    assert {:ok, %{hidden_heading_at: 5}} =
             Sections.find(content, "A", 2)

    assert Sections.insert(content, "A", 2, "end", "n1") == {:error, {:hidden_heading, 5}}
  end

  test "an unclosed fence that swallows no heading is not flagged" do
    assert {:ok, %{stop: 3, hidden_heading_at: nil}} =
             Sections.find("## A\n#{@bt}\ncode\n", "A", 2)
  end

  test "an unclosed fence swallowing only a DEEPER heading is not flagged" do
    assert {:ok, %{hidden_heading_at: nil}} = Sections.find("## A\n#{@bt}\n### c\n", "A", 2)
  end

  test "an unclosed HTML comment that swallows a heading is flagged" do
    content = "## A\n<!--\n## B\nkeep\n"
    assert lt(content) == [{0, "A"}]
    assert {:ok, %{hidden_heading_at: 2}} = Sections.find(content, "A", 2)
  end

  test "an unclosed comment that swallows no ending heading is not flagged" do
    assert {:ok, %{hidden_heading_at: nil}} = Sections.find("## A\n%%\nnote\n### c\n", "A", 2)
    assert {:ok, %{hidden_heading_at: nil}} = Sections.find("## A\n<!--\nnote\n", "A", 2)
  end

  # I2: lazy continuation lines belong to the list item / blockquote
  # paragraph, so the underline after them is not a setext underline.
  test "a --- after a list item's continuation line is a thematic break, not setext" do
    assert lt("## A\n- first point\n  more about it\n---\n\nrest of A\n## B") ==
             [{0, "A"}, {6, "B"}]
  end

  test "an === after a blockquote lazy continuation is not setext" do
    assert lt("## A\n> quote\nlazy line\n===") == [{0, "A"}]
  end

  # Only document-level headings are section boundaries.
  test "headings inside a blockquote, callout or list item do not count" do
    content = "## A\n> ## Q\n\n> [!note] T\n> ## C\n\n- ## L\n  ## L2\n\n## B\n"
    assert lt(content) == [{0, "A"}, {9, "B"}]
    assert {:ok, text} = Sections.section(content, "A")
    assert text =~ "> ## Q"
    assert text =~ "  ## L2"
  end

  test "a GFM table does not produce a setext heading and does not end a section" do
    content = "## A\n| h |\n| --- |\n| v |\n\nx\n===\n## B\n"

    assert headings!(content) |> Enum.map(&{&1.line, &1.level, &1.text}) ==
             [{0, 2, "A"}, {5, 1, "x"}, {7, 2, "B"}]
  end

  test "%% inside a fenced code block does not open a comment" do
    content = "## A\n#{@bt}\n%%\n#{@bt}\n## B\nkeep\n"
    assert lt(content) == [{0, "A"}, {4, "B"}]
    assert {:ok, %{hidden_heading_at: nil}} = Sections.find(content, "A", 2)
  end

  test "an inline %% comment masks only its own text, and an unclosed one hides the rest" do
    content = "## A %% hidden %%\n%% x\n## H\n%%\n## B %% y\n## C"
    assert lt(content) == [{0, "A"}, {4, "B"}]
  end

  test "heading text is the rendered inline text" do
    assert lt("## **Bold** `code` ~~s~~ [l](u) \\# &amp; ##\n") == [{0, "Bold code s l # &"}]
  end

  test "a lone CR is not a line break for line numbering" do
    assert lt("a\rb\n## H\n") == [{1, "H"}]
  end

  test "CRLF frontmatter is skipped and line numbers are preserved" do
    assert lt("---\r\ntitle: x\r\n---\r\n# X\r\n") == [{3, "X"}]
  end

  # I3: a long run of spaces must not make a heading silently disappear
  # (the old regex hit PCRE's match limit and returned no match).
  test "a heading with 12000 spaces inside is still a heading" do
    content = "## A\na\n## B" <> String.duplicate(" ", 12_000) <> "x\nkeep\n"
    assert [{0, "A"}, {2, b}] = lt(content)
    assert String.starts_with?(b, "B ") and String.ends_with?(b, " x")
    assert {:ok, %{stop: 2}} = Sections.find(content, "A", 2)
  end

  # I3: the old scanner took ~26 s on a 9 MB note. There is no size cap
  # (concurrency is bounded by Engram.MCP.ParseGate instead), so a large note
  # of ordinary prose must parse well within budget.
  test "headings on a ~9 MB note of ordinary prose finishes in under 2 seconds" do
    para =
      String.duplicate("Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do. ", 12) <>
        "\n\n"

    big =
      ["## Heading\n\n", para, para, para] |> Stream.cycle() |> Enum.take(16_000) |> Enum.join()

    assert byte_size(big) > 9_000_000
    # Its own gate: waits on the shared gate must not count toward the bound.
    g = start_supervised!({Engram.MCP.ParseGate, name: nil, limit: 1})
    {micros, {:ok, hs}} = :timer.tc(fn -> Sections.headings(big, gate: g) end)
    assert length(hs) == 4_000
    assert micros < 2_000_000, "took #{div(micros, 1000)} ms"
  end

  # --- Fix round (adversarial review of the MDEx swap) ---

  test "a note over 1 MB is parsed and edited like any other (no size cap)" do
    big = "## A\n" <> String.duplicate("x", 1_200_000) <> "\n## B\nb\n"
    assert {:ok, [%{text: "A"}, %{text: "B", line: 2}]} = Sections.headings(big)
    assert {:ok, %{start: 0, stop: 2}} = Sections.find(big, "A", 2)
    assert {:ok, out} = Sections.insert(big, "A", 2, "start", "y")
    assert String.starts_with?(out, "## A\ny\nxxx")
  end

  # F1: an unclosed HTML block of types 1, 3, 4, 5 (and 6/7, which end only
  # at a blank line) hides the next heading; a write must refuse.
  for opener <- ~w(<pre> <script> <style> <textarea> <?php <!DOCTYPE <![CDATA[ <div>) do
    test "an unclosed #{opener} block hiding the next heading refuses the write" do
      content = "## A\n#{unquote(opener)}\ncode\n## B\nimportant\n"
      assert {:ok, %{hidden_heading_at: 3}} = Sections.find(content, "A", 2)
      assert Sections.insert(content, "A", 2, "end", "y") == {:error, {:hidden_heading, 3}}
    end
  end

  # F2: a backtick inside a %% comment mis-pairs the %% marks and hides B.
  test "a heading hidden by mis-paired %% marks refuses the write" do
    content = "## A\n%% note ` %% and `y`\n## B\nimportant\n%% c2 %%\n"
    assert {:ok, %{hidden_heading_at: 2}} = Sections.find(content, "A", 2)
  end

  test "a legit multi-line %% comment holding a heading refuses (accepted false refuse)" do
    content = "## A\n%%\n## draft\n%%\nbody\n## B\n"
    assert {:ok, %{stop: 5, hidden_heading_at: 2}} = Sections.find(content, "A", 2)
  end

  test "a heading-shaped line in a CLOSED fence does not refuse" do
    content = "## A\n#{@bt}bash\n# comment\n## x\n#{@bt}\n## B\n"
    assert {:ok, %{stop: 5, hidden_heading_at: nil}} = Sections.find(content, "A", 2)
  end

  test "a heading-shaped line in a CLOSED fence inside a list item does not refuse" do
    content = "## A\n- step\n  #{@bt}\n  ## x\n  #{@bt}\n## B\n"
    assert {:ok, %{stop: 5, hidden_heading_at: nil}} = Sections.find(content, "A", 2)
  end

  test "a heading-shaped line in a CLOSED HTML comment block does not refuse" do
    content = "## A\n<!--\n## x\n-->\n## B\n"
    assert {:ok, %{stop: 4, hidden_heading_at: nil}} = Sections.find(content, "A", 2)
  end

  test "a heading nested in a list item is a heading, not a hidden one" do
    content = "## A\n- item\n\n  ## nested\n## B\n"
    assert {:ok, %{stop: 4, hidden_heading_at: nil}} = Sections.find(content, "A", 2)
  end

  test "a hidden DEEPER heading-shaped line does not refuse" do
    assert {:ok, %{hidden_heading_at: nil}} =
             Sections.find("## A\n<pre>\n### c\n", "A", 2)
  end

  # F3: the raw heading text wins over another heading that only RENDERS to it.
  for {styled, plain} <- [
        {"**A**", "A"},
        {"a &amp; b", "a & b"},
        {"`x`", "x"},
        {"[x](u)", "x"}
      ] do
    test "#{plain} picks the plain heading over #{styled}" do
      content = "## #{unquote(styled)}\nstyled\n## #{unquote(plain)}\nplain\n"
      assert {:ok, %{start: 2}} = Sections.find(content, unquote(plain), 2)
      assert {:ok, "## " <> _ = text} = Sections.section(content, unquote(plain))
      assert text =~ "plain"
      assert {:ok, %{start: 0}} = Sections.find(content, unquote(styled), 2)
    end
  end

  # F4: raw markup matches as written, and the rendered form still matches
  # when exactly one heading renders to it.
  for {raw, rendered} <- [
        {"**Bold**", "Bold"},
        {"`code`", "code"},
        {"[l](u)", "l"},
        {"a &amp; b", "a & b"},
        {"\\#x", "#x"}
      ] do
    test "raw #{raw} and rendered #{rendered} both match" do
      content = "## #{unquote(raw)} ##\nbody\n## Next\n"
      assert {:ok, %{start: 0, stop: 2}} = Sections.find(content, unquote(raw), 2)
      assert {:ok, %{start: 0, stop: 2}} = Sections.find(content, unquote(rendered), 2)
    end
  end

  test "rendered text shared by several headings (none raw) is ambiguous" do
    content = "## **A**\nx\n## *A*\ny\n"
    assert Sections.find(content, "A", 2) == {:error, :ambiguous}
    assert Sections.section(content, "A") == {:error, :ambiguous}
    assert Sections.insert(content, "A", 2, "end", "z") == {:error, :ambiguous}
  end

  test "raw match is at the requested level; a rendered match elsewhere does not count" do
    content = "# **A**\nx\n## A\ny\n"
    assert {:ok, %{start: 0}} = Sections.find(content, "A", 1)
    assert {:ok, %{start: 2}} = Sections.find(content, "A", 2)
  end

  test "a multi-line setext heading matches on its joined raw lines" do
    content = "**a**\nb\n===\nx\n"
    assert {:ok, %{start: 0, span: 3}} = Sections.find(content, "**a** b", 1)
    assert {:ok, %{start: 0}} = Sections.find(content, "a b", 1)
  end

  # F6 (fails safe): a lone CR merges two lines in the parse; find must say
  # :error rather than return a range built on the merged line.
  test "a lone CR inside a heading line gives :error, not a wrong range" do
    assert Sections.find("## A\rx\n## B\n", "A", 2) == :error
  end

  # --- Fix round 2 ---

  # A hidden SETEXT heading must refuse the write too, not just an ATX one.
  test "a setext heading hidden by mis-paired %% marks refuses the write" do
    content = "## A\n%% note ` %% and `y`\nB\n---\nimportant\n%% c2 %%\n"
    assert {:ok, %{hidden_heading_at: 2}} = Sections.find(content, "A", 2)
    assert Sections.insert(content, "A", 2, "end", "y") == {:error, {:hidden_heading, 2}}
  end

  test "a setext heading hidden in an unclosed <pre> block refuses the write" do
    assert {:ok, %{hidden_heading_at: 2}} =
             Sections.find("## A\n<pre>\nB\n---\nimportant\n", "A", 2)
  end

  test "a hidden setext level-2 underline does not refuse a level-1 section" do
    assert {:ok, %{hidden_heading_at: nil}} = Sections.find("# A\n<pre>\nB\n---\n", "A", 1)
    assert {:ok, %{hidden_heading_at: 2}} = Sections.find("# A\n<pre>\nB\n===\n", "A", 1)
  end

  test "an x/--- pair inside a CLOSED fence still edits" do
    content = "## A\n#{@bt}\nx\n---\n#{@bt}\n## B\n"
    assert {:ok, %{stop: 5, hidden_heading_at: nil}} = Sections.find(content, "A", 2)
  end

  test "a real setext heading ends the section and is not hidden" do
    content = "## A\na\n\nB\n---\nb\n"
    assert {:ok, %{stop: 3, hidden_heading_at: nil}} = Sections.find(content, "A", 2)
    assert {:ok, %{start: 3, span: 2, hidden_heading_at: nil}} = Sections.find(content, "B", 2)
  end

  test "a thematic break under a list item or after a blank line is not a hidden heading" do
    assert {:ok, %{hidden_heading_at: nil}} = Sections.find("## A\n- item\n---\nx\n", "A", 2)
    assert {:ok, %{hidden_heading_at: nil}} = Sections.find("## A\npara\n\n---\nx\n", "A", 2)
  end

  test "a setext heading nested in a list item is a heading, not a hidden one" do
    assert {:ok, %{hidden_heading_at: nil}} =
             Sections.find("## A\n- item\n  sub\n  ---\n## B\n", "A", 2)
  end

  # Invalid UTF-8 would make the NIF raise; refuse it as a fixable error.
  test "invalid UTF-8 is a fixable error at every entry point" do
    bad = "## A\n" <> <<0xFF, 0xFE>> <> "\n"
    assert Sections.headings(bad) == {:error, :invalid_utf8}
    assert Sections.find(bad, "A", 2) == {:error, :invalid_utf8}
    assert Sections.section(bad, "A") == {:error, :invalid_utf8}
    assert Sections.insert(bad, "A", 2, "end", "y") == {:error, :invalid_utf8}
  end

  test "a section miss returns the note's headings from the same parse" do
    assert {:error, {:not_found, [%{text: "A"}, %{text: "B"}]}} =
             Sections.section("## A\n\n## B\n", "Nope")
  end

  # Shape contract for the pinned mdex_native AST: a dependency bump that
  # changes any struct, field or sourcepos convention Sections relies on must
  # fail here, loudly, instead of silently mis-finding sections.
  test "the mdex_native AST has the shape Sections relies on" do
    md = "## é **B**\n\n#{@bt}\nx\n#{@bt}\n<!-- c -->\n\nS\n===\n\n`é%%` t\n\n#{@bt}\nopen\n"
    %MDExNative.Comrak.Document{nodes: nodes} = MDExNative.Comrak.parse_document(md, [])

    assert [
             %MDExNative.Comrak.Heading{level: 2, setext: false, nodes: [_ | _]} = h,
             %MDExNative.Comrak.CodeBlock{fenced: true, closed: true} = cb,
             %MDExNative.Comrak.HtmlBlock{block_type: 2, literal: "<!-- c -->\n"},
             %MDExNative.Comrak.Heading{level: 1, setext: true} = sh,
             %MDExNative.Comrak.Paragraph{nodes: [%MDExNative.Comrak.Code{} = code | _]},
             %MDExNative.Comrak.CodeBlock{fenced: true, closed: false}
           ] = nodes

    # Lines are 1-based; columns are 1-based BYTE offsets ("é" is 2 bytes).
    # 11 bytes, 10 characters: columns count bytes.
    assert %{start: {1, 1}, end: {1, 11}} = Map.from_struct(h.sourcepos)
    assert [%MDExNative.Comrak.Text{sourcepos: %{start: {1, 4}}} | _] = h.nodes
    assert %{start: {3, 1}, end: {5, 3}} = Map.from_struct(cb.sourcepos)
    assert %{start: {8, 1}, end: {9, 3}} = Map.from_struct(sh.sourcepos)
    # A code span's sourcepos includes its backticks.
    assert %{start: {11, 1}, end: {11, 6}} = Map.from_struct(code.sourcepos)
  end

  # --- Final review: linear hidden-heading check, math blocks ---

  # Was O(lines x closed fences) outside the gate: 20k blocks took ~5.6 s.
  test "find over 20k closed fences holding # lines is linear" do
    content = "# A\n" <> String.duplicate("#{@bt}\n# a\n#{@bt}\n", 20_000) <> "# B\n"
    g = start_supervised!({Engram.MCP.ParseGate, name: nil, limit: 1})
    {micros, result} = :timer.tc(fn -> Sections.find(content, "A", 1, gate: g) end)
    assert {:ok, %{stop: 60_001, hidden_heading_at: nil}} = result
    assert micros < 2_000_000, "took #{div(micros, 1000)} ms"
  end

  # Obsidian $$ display math is block-level: its lines are not markdown.
  test "a heading-shaped line inside a $$ math block is not a heading and not hidden" do
    content = "## A\n$$\n## x\n$$\nkeep\n## B\n"
    assert lt(content) == [{0, "A"}, {5, "B"}]
    assert {:ok, %{stop: 5, hidden_heading_at: nil}} = Sections.find(content, "A", 2)
  end

  test "$$ inside a fenced code block does not open a math block" do
    content = "## A\n#{@bt}\n$$\n#{@bt}\n## B\n$$\n"
    assert lt(content) == [{0, "A"}, {4, "B"}]
  end

  test "an unclosed $$ is left alone" do
    assert lt("## A\n$$\n## B\n") == [{0, "A"}, {2, "B"}]
  end

  # A mis-paired $$ used to mask a real heading AND allow-list it, so a
  # replace_section of A silently deleted B.
  test "$$ inside an HTML comment or HTML block does not pair" do
    for content <- [
          "## A\n<!--\n$$\n-->\n## B\nb\n$$\n",
          "## A\n<div>\n$$\n</div>\n\n## B\nb\n$$\n"
        ] do
      b = Enum.find_index(String.split(content, "\n"), &(&1 == "## B"))
      assert {:ok, %{stop: ^b}} = Sections.find(content, "A", 2), inspect(content)
    end
  end

  test "a $$ with text on its line is a delimiter too" do
    content = "## A\n$$x\n$$\n## B\n$$\ny\n$$\n"
    assert lt(content) == [{0, "A"}, {3, "B"}]
    assert {:ok, %{stop: 3}} = Sections.find(content, "A", 2)
  end

  test "an odd number of $$ masks nothing" do
    content = "## A\n$$\n## x\n$$\n$$\n## B\n"
    assert lt(content) == [{0, "A"}, {2, "x"}, {5, "B"}]
  end

  test "inline $$math$$ on one line does not blank the line" do
    content = "## A\ntext $$a$$\n---\n## B\n"
    assert lt(content) == [{0, "A"}, {1, "text $$a$$"}, {3, "B"}]
  end

  # Two math pairs sharing a line (`$$ ... $$` on the middle one) blank
  # overlapping line ranges. The Elixir masker assumed disjoint ranges and
  # re-inserted the shared line, whose "\r" then counted as an extra line:
  # B was reported one line late, so a section read of A included "# B".
  test "math pairs sharing a CRLF line keep line numbers" do
    content = "# A\n\n$$\nx $$ y $$\r\nz\n$$\n\n# B\nbody\n"
    assert lt(content) == [{0, "A"}, {7, "B"}]
    assert {:ok, %{stop: 7, hidden_heading_at: nil}} = Sections.find(content, "A", 1)
  end
end
