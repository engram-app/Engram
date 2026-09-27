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

  # Lines that CANNOT start (or, for most, continue) a setext paragraph:
  #
  # - An indented code line (4+ spaces, or any tab -- a tab is a 4-column
  #   stop). This one is different from the rest: it only blocks the FIRST
  #   line of a paragraph. On a CONTINUATION line (there's already a `prev`
  #   paragraph), CommonMark treats it as a "lazy continuation" -- still
  #   plain text, just indented.
  # - After stripping up to 3 leading spaces: a bullet list marker (with or
  #   without content -- an empty item like "-" still starts a list), a
  #   blockquote marker, or the start of a real HTML block (see
  #   @html_block_start_re below -- NOT any line starting with "<": inline
  #   HTML and autolinks are ordinary paragraph text).
  # - An ordered list marker only blocks when there's no `prev` paragraph
  #   (any list can START a block) OR when it starts at 1 (only a
  #   start-at-1 ordered list can INTERRUPT an existing paragraph; "2. b"
  #   mid-paragraph is lazy continuation text, marker included verbatim).
  @indented_code_re ~r/^(?: {4,}|\t)/
  @bullet_re ~r/^[-+*](?:[ \t]|$)/
  @blockquote_re ~r/^>/
  @ordered_re ~r/^(\d{1,9})[.)](?:[ \t]|$)/
  @leading_indent_re ~r/^ {0,3}/

  # CommonMark 4.6 HTML block start conditions (types 1-6), collapsed into
  # one regex, applied to the line with its indent already stripped:
  # type 1 (script/pre/style/textarea), type 2 (a comment -- also handled as
  # its own multi-line scan state, see html_comment_open?/1, but a
  # self-closing single-line comment falls through to here), type 3 (a
  # processing instruction), type 4 (a declaration, e.g. "<!DOCTYPE"), type
  # 5 (CDATA), and type 6 (an opening or closing block-level tag from
  # CommonMark's fixed list). Inline tags like "<b>" or "<a>" match none of
  # these, so they're ordinary paragraph text.
  @html_block_tags ~w(
    address article aside base basefont blockquote body caption center col
    colgroup dd details dialog dir div dl dt fieldset figcaption figure
    footer form frame frameset h1 h2 h3 h4 h5 h6 head header hr html iframe
    legend li link main menu menuitem nav noframes ol optgroup option p
    param section summary table tbody td tfoot th thead title tr track ul
  ) |> Enum.join("|")

  @html_block_start_re ~r/^(?:<(?:script|pre|style|textarea)(?:[\s>]|$)|<!--|<\?|<![A-Za-z]|<!\[CDATA\[|<\/?(?:#{@html_block_tags})(?:[\s>]|\/>|$))/i

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

      {lines, text} = splice_eol(lines, at, at, text, content)
      {:ok, lines |> List.insert_at(at, text) |> Enum.join("\n")}
    end
  end

  # Makes `text`'s line endings match `source`'s (the note being edited).
  # Per-line, so it only ever touches the FRAGMENT being written -- never the
  # untouched lines around it, even in a note that mixes a CRLF line with LF
  # lines elsewhere.
  @spec match_eol(String.t(), String.t()) :: String.t()
  def match_eol(text, source) do
    if String.contains?(source, "\r\n") do
      text |> String.split("\n") |> Enum.map_join("\n", &(String.trim_trailing(&1, "\r") <> "\r"))
    else
      text
    end
  end

  # match_eol/2 alone assumes the fragment is always followed by more
  # content (so its own last line can safely end in "\r", relying on the
  # next line to supply the pairing "\n"). That's false exactly when the
  # fragment lands as the new end of file in a note with no trailing
  # newline: the line that WAS last never got a "\r" (nothing followed it),
  # and the fragment must not gain a stray trailing "\r" either (source had
  # no trailing newline, so neither should the result).
  #
  # `before_count` is where the fragment is inserted relative to `lines`
  # (`Enum.slice(lines, 0, before_count)` is what precedes it); `after_from`
  # is where the untouched remainder resumes (`Enum.drop(lines, after_from)`
  # -- equal to `before_count` for a pure insert with nothing removed, but
  # can be larger for a replace that removes a range).
  @spec splice_eol([String.t()], non_neg_integer(), non_neg_integer(), String.t(), String.t()) ::
          {[String.t()], String.t()}
  def splice_eol(lines, before_count, after_from, text, source) do
    if String.contains?(source, "\r\n") do
      n = length(lines)
      no_trailing_nl = not String.ends_with?(source, "\n")

      lines =
        if before_count == n and no_trailing_nl,
          do: List.update_at(lines, before_count - 1, &(&1 <> "\r")),
          else: lines

      text = match_eol(text, source)

      text =
        if after_from >= n and no_trailing_nl, do: String.trim_trailing(text, "\r"), else: text

      {lines, text}
    else
      {lines, text}
    end
  end

  # Not currently fenced/commented: an opening fence, an unclosed HTML
  # comment, or an unclosed Obsidian %% comment starts a block; otherwise
  # look for an ATX or setext heading (scan_open/4). Inside a fence, only a
  # closing fence (same char, no info string, length >= opener) ends it.
  # Inside an HTML or %% comment, only a line CONTAINING the closer ends it
  # (the closer need not START the line, unlike a fence, so each gets its
  # own state rather than reusing fence_close/1). Everything inside any of
  # these, including a `---`/`===` line, is invisible to heading detection.
  defp scan({line, i}, {acc, nil, prev}) do
    cond do
      (marker = fence_open(line)) != nil -> {acc, marker, nil}
      html_comment_open?(line) -> {acc, :html_comment, nil}
      obsidian_comment_open?(line) -> {acc, :obsidian_comment, nil}
      true -> scan_open(line, i, acc, prev)
    end
  end

  defp scan({line, _i}, {acc, :html_comment, _prev}) do
    if String.contains?(line, "-->"), do: {acc, nil, nil}, else: {acc, :html_comment, nil}
  end

  defp scan({line, _i}, {acc, :obsidian_comment, _prev}) do
    if String.contains?(line, "%%"), do: {acc, nil, nil}, else: {acc, :obsidian_comment, nil}
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

  # A line with an ODD number of "%%" occurrences has an opener with no
  # matching closer on the same line (e.g. a lone "%%", or "%% starts a
  # block"). A single self-contained "%% note %%" has an EVEN count (open +
  # close both present) and does not start a multi-line block.
  defp obsidian_comment_open?(line) do
    line |> String.split("%%") |> length() |> Kernel.-(1) |> rem(2) == 1
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
  # line `paragraph_line?/2` rejects all reset `prev` to `nil`, so a `---`
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

      paragraph_line?(line, prev) ->
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

  defp paragraph_line?(line, prev) do
    if Regex.match?(@indented_code_re, line) do
      # 4+ indent (or a tab) blocks only the FIRST line of a paragraph; a
      # continuation line is a lazy continuation, still paragraph text.
      match?({:para, _, _}, prev)
    else
      not blocks_paragraph?(Regex.replace(@leading_indent_re, line, ""), prev)
    end
  end

  defp blocks_paragraph?(trimmed, prev) do
    cond do
      Regex.match?(@bullet_re, trimmed) ->
        true

      Regex.match?(@blockquote_re, trimmed) ->
        true

      Regex.match?(@html_block_start_re, trimmed) ->
        true

      true ->
        case {Regex.run(@ordered_re, trimmed), prev} do
          # No ongoing paragraph: any ordered marker (any start number)
          # starts a list, never paragraph text.
          {[_, _n], nil} -> true
          # An ongoing paragraph: only a start-at-1 marker interrupts it;
          # any other number is lazy continuation text (the marker stays
          # in the joined text).
          {[_, n], {:para, _, _}} -> n == "1"
          {nil, _} -> false
        end
    end
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
