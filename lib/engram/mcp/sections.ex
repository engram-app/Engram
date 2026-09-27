defmodule Engram.MCP.Sections do
  @moduledoc """
  Markdown heading lookup shared by edit_note (replace_section,
  insert_section) and get_notes (section, outline). Pure: string in, data out.

  Lines inside the frontmatter block or a fenced code block are never
  headings, so a YAML `# comment` or a shell `# comment` in a fence can
  neither be matched nor end a section early. Setext headings (a paragraph
  line underlined with `=`/`-`) are recognized alongside ATX (`#`) headings.
  A leading UTF-8 BOM is ignored for scanning only; line numbers and any
  content this module returns are unaffected by it.
  """

  alias Engram.Notes.Frontmatter

  @type heading :: %{line: non_neg_integer(), level: 1..6, text: String.t(), span: pos_integer()}

  @bom "﻿"

  # `\#` because `#{` would interpolate. Leading ` {0,3}` mirrors CommonMark:
  # at most 3 spaces of indent, 4+ (or any tab, which is a 4-column stop) is
  # an indented code line, not a heading (same bound as the fence and setext
  # regexes below). The trailing `(?:\s+#+)?` strips an optional ATX closing
  # sequence ("## Title ##" -> "Title"); it must be preceded by whitespace, so
  # "## Title##" keeps the hashes as text. Trailing `\s*` also eats a CRLF `\r`.
  @heading_re ~r/^ {0,3}(\#{1,6})(?:\s+(.*?))?(?:\s+#+)?\s*$/

  # Opening fence: captures the marker run and the rest of the line (info
  # string). Closing fence: no info string allowed, only trailing spaces/tabs
  # and an optional \r.
  @fence_open_re ~r/^ {0,3}(`{3,}|~{3,})(.*)$/
  @fence_close_re ~r/^ {0,3}(`{3,}|~{3,})[ \t]*\r?$/

  # A setext underline: 0-3 space indent, then a run of ONLY `=` (level 1) or
  # ONLY `-` (level 2), optional trailing spaces/tabs, optional \r. "- item"
  # fails this (has non-underline text after the dash), so list items are
  # never mistaken for one. "- - -" (spaced dashes) also fails: `-+` is a
  # contiguous run, so it does not match the FULL line.
  @setext_re ~r/^ {0,3}(=+|-+)[ \t]*\r?$/

  # A line that CANNOT start or continue a setext paragraph, even though it's
  # non-blank: an indented code line (4+ spaces, or any tab -- a tab is a
  # 4-column stop); or, after stripping up to 3 leading spaces, a list
  # marker (bullet or ordered), a blockquote marker, or an HTML block start.
  # CommonMark interrupts a paragraph at any of these, so they can never be
  # "the paragraph line" a setext underline attaches to.
  @indented_code_re ~r/^(?: {4,}|\t)/
  @non_paragraph_re ~r/^(?:[-+*][ \t]|\d{1,9}[.)][ \t]|>|<)/
  @leading_indent_re ~r/^ {0,3}/

  @spec headings(String.t()) :: [heading()]
  def headings(content) do
    scan_content = String.replace_prefix(content, @bom, "")

    {found, _fence, _prev} =
      scan_content
      |> String.split("\n")
      |> Enum.with_index()
      |> Enum.drop(frontmatter_lines(scan_content))
      |> Enum.reduce({[], nil, nil}, &scan/2)

    Enum.reverse(found)
  end

  @spec find(String.t(), String.t(), 1..6 | nil) ::
          {:ok, %{start: non_neg_integer(), stop: non_neg_integer(), span: pos_integer()}}
          | :error
  def find(content, heading, level) do
    hs = headings(content)
    want = String.trim(heading)

    case Enum.find(hs, &(&1.text == want and (is_nil(level) or &1.level == level))) do
      nil ->
        :error

      h ->
        line_count = content |> String.split("\n") |> length()

        stop =
          Enum.find_value(hs, line_count, fn x ->
            x.line > h.line and x.level <= h.level and x.line
          end)

        {:ok, %{start: h.line, stop: stop, span: h.span}}
    end
  end

  @spec section(String.t(), String.t()) :: {:ok, String.t()} | :error
  def section(content, heading) do
    with {:ok, %{start: s, stop: e}} <- find(content, heading, nil) do
      text =
        content
        |> String.split("\n")
        |> Enum.slice(s, e - s)
        |> Enum.join("\n")
        |> String.trim_trailing()

      {:ok, text}
    end
  end

  # "start": directly under the heading (after the underline, for a setext
  # heading). "end": after the section's last non-blank line, so blank lines
  # before the next heading stay where they are.
  @spec insert(String.t(), String.t(), 1..6, String.t(), String.t()) :: {:ok, String.t()} | :error
  def insert(content, heading, level, position, text) do
    with {:ok, %{start: s, stop: e, span: span}} <- find(content, heading, level) do
      lines = String.split(content, "\n")
      text = String.trim_trailing(text, "\n")

      at =
        case position do
          "start" ->
            s + span

          "end" ->
            # The heading line itself is non-blank, so this always finds one.
            back =
              lines
              |> Enum.slice(s, e - s)
              |> Enum.reverse()
              |> Enum.find_index(&(String.trim(&1) != ""))

            e - back
        end

      result = lines |> List.insert_at(at, text) |> Enum.join("\n")
      {:ok, match_eol(result, content)}
    end
  end

  # Makes `text`'s line endings match `source`'s (the note being edited),
  # called on the FULLY joined result so a write never leaves a mix of bare
  # LF and CRLF behind. Normalizing to LF first (rather than only replacing
  # bare "\n") avoids doubling a "\r" that was already there, and leaves any
  # trailing-newline convention (or lack of one) exactly as `text` already
  # has it -- no separate handling needed for "insert landed at end of file
  # with no trailing newline".
  @spec match_eol(String.t(), String.t()) :: String.t()
  def match_eol(text, source) do
    if String.contains?(source, "\r\n") do
      text |> String.replace("\r\n", "\n") |> String.replace("\n", "\r\n")
    else
      text
    end
  end

  # Not currently fenced/commented: an opening fence or an unclosed HTML
  # comment starts a block; otherwise look for an ATX or setext heading
  # (scan_open/4). Inside a fence, only a closing fence (same char, no info
  # string, length >= opener) ends it. Inside an HTML comment, only a line
  # containing "-->" ends it (its closer need not START the line, unlike a
  # fence, so it gets its own state rather than reusing fence_close/1).
  # Everything inside either block, including a `---`/`===` line, is
  # invisible to heading detection.
  defp scan({line, i}, {acc, nil, prev}) do
    case fence_open(line) do
      nil ->
        if html_comment_open?(line),
          do: {acc, :html_comment, nil},
          else: scan_open(line, i, acc, prev)

      marker ->
        {acc, marker, nil}
    end
  end

  defp scan({line, _i}, {acc, :html_comment, _prev}) do
    if String.contains?(line, "-->"), do: {acc, nil, nil}, else: {acc, :html_comment, nil}
  end

  defp scan({line, _i}, {acc, fence, _prev}) do
    case fence_close(line) do
      nil -> {acc, fence, nil}
      marker -> if closes?(fence, marker), do: {acc, nil, nil}, else: {acc, fence, nil}
    end
  end

  defp html_comment_open?(line) do
    trimmed = Regex.replace(@leading_indent_re, line, "")
    String.starts_with?(trimmed, "<!--") and not String.contains?(trimmed, "-->")
  end

  defp scan_open(line, i, acc, prev) do
    case Regex.run(@heading_re, line) do
      [_, hashes] -> {[atx(i, hashes, "") | acc], nil, nil}
      [_, hashes, text] -> {[atx(i, hashes, text) | acc], nil, nil}
      nil -> scan_text(line, i, acc, prev)
    end
  end

  defp atx(i, hashes, text), do: %{line: i, level: String.length(hashes), text: text, span: 1}

  # A setext heading only forms when the immediately preceding line(s) were
  # plain paragraph text (`prev` is `{:para, start_line, texts}`, `texts`
  # accumulating one entry per consecutive paragraph line, most recent
  # first). A blank line, an ATX heading, a fence (open or close), or any
  # line `paragraph_line?/1` rejects all reset `prev` to `nil`, so a `---`
  # right after any of those is a thematic break, not a heading -- and it
  # does NOT become a new paragraph candidate itself, so two underline-shaped
  # lines in a row can't chain into a heading either. The heading's `line` is
  # the FIRST paragraph line, `span` covers every paragraph line plus the
  # underline, and `text` joins the paragraph lines with a single space.
  defp scan_text(line, i, acc, prev) do
    cond do
      String.trim(line) == "" ->
        {acc, nil, nil}

      (level = setext_level(line)) != nil ->
        case prev do
          {:para, start, texts} ->
            text = texts |> Enum.reverse() |> Enum.join(" ")
            {[%{line: start, level: level, text: text, span: length(texts) + 1} | acc], nil, nil}

          nil ->
            {acc, nil, nil}
        end

      paragraph_line?(line) ->
        case prev do
          {:para, start, texts} -> {acc, nil, {:para, start, [String.trim(line) | texts]}}
          nil -> {acc, nil, {:para, i, [String.trim(line)]}}
        end

      true ->
        {acc, nil, nil}
    end
  end

  defp setext_level(line) do
    case Regex.run(@setext_re, line) do
      [_, run] -> if String.starts_with?(run, "="), do: 1, else: 2
      nil -> nil
    end
  end

  defp paragraph_line?(line) do
    not Regex.match?(@indented_code_re, line) and
      not Regex.match?(@non_paragraph_re, Regex.replace(@leading_indent_re, line, ""))
  end

  # A backtick fence's info string may not itself contain a backtick
  # (CommonMark: ambiguous with inline code spans); a tilde fence's may
  # contain anything, backticks included.
  defp fence_open(line) do
    case Regex.run(@fence_open_re, line) do
      [_, marker, rest] ->
        if String.starts_with?(marker, "`") and String.contains?(rest, "`"), do: nil, else: marker

      nil ->
        nil
    end
  end

  defp fence_close(line) do
    case Regex.run(@fence_close_re, line) do
      [_, marker] -> marker
      nil -> nil
    end
  end

  # A fence closes on the same character, at least as long as the opener.
  defp closes?(open, marker),
    do:
      String.first(open) == String.first(marker) and
        String.length(marker) >= String.length(open)

  # Lines taken by the frontmatter block, so the scan starts after it.
  defp frontmatter_lines(content) do
    case Frontmatter.split(content) do
      {nil, _body} ->
        0

      {_block, body} ->
        prefix = String.replace_suffix(content, body, "")
        n = prefix |> String.split("\n") |> length()
        if String.ends_with?(prefix, "\n"), do: n - 1, else: n
    end
  end
end
