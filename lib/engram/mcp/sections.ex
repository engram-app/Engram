defmodule Engram.MCP.Sections do
  @moduledoc """
  Markdown heading lookup shared by edit_note (replace_section,
  insert_section) and get_notes (section, outline). Pure: string in, data out.

  Where a heading is, and where its section ends, comes from a CommonMark
  parser (MDEx, i.e. comrak) with source positions, never from a hand-written
  line scanner: every scanner bug here was a silent data-loss bug, because a
  missed next heading makes replace_section overwrite the rest of the note.

  Only DOCUMENT-LEVEL headings count. A heading inside a blockquote, callout
  (`> [!note]`) or list item is content of that block, not a section
  boundary. Two things CommonMark does not know about are handled before
  parsing, both preserving line numbers:

    * the frontmatter block (`Engram.Notes.Frontmatter.split/1`, the same
      rule the rest of Engram uses) is blanked out;
    * Obsidian `%% comments %%` outside code are masked to spaces (an
      unclosed `%%` hides the rest of the note, as in Obsidian).

  A leading UTF-8 BOM is ignored; line numbers index
  `String.split(content, "\\n")` and are unaffected by it.
  """

  alias Engram.Notes.Frontmatter

  @type heading :: %{line: non_neg_integer(), level: 1..6, text: String.t(), span: pos_integer()}

  @bom "﻿"

  # GFM tables (so a delimiter row is never a setext underline) and
  # strikethrough (heading text), matching what Obsidian renders. Raw HTML
  # stays at the CommonMark default. Frontmatter is NOT comrak's
  # front_matter_delimiter: Frontmatter.split/1 is Engram's one definition of
  # it (CRLF fences included), so it is blanked out before parsing instead.
  @parse_opts [extension: [table: true, strikethrough: true]]

  @spec headings(String.t()) :: [heading()]
  def headings(content), do: analyze(content).headings

  @spec find(String.t(), String.t(), 1..6 | nil) ::
          {:ok,
           %{
             start: non_neg_integer(),
             stop: non_neg_integer(),
             span: pos_integer(),
             unclosed_comment_at: non_neg_integer() | nil
           }}
          | :error
  def find(content, heading, level) do
    %{headings: hs, blocker: blocker} = analyze(content)
    want = String.trim(heading)

    case Enum.find(hs, &(&1.text == want and (is_nil(level) or &1.level == level))) do
      nil ->
        :error

      h ->
        # The section never owns the empty "line" after a trailing newline,
        # so a replace of the last section keeps the note's final newline.
        eof = content |> String.split("\n") |> length()
        eof = if String.ends_with?(content, "\n"), do: eof - 1, else: eof

        stop =
          Enum.find_value(hs, eof, fn x -> x.line > h.line and x.level <= h.level and x.line end)

        {:ok,
         %{
           start: h.line,
           stop: stop,
           span: h.span,
           unclosed_comment_at: unclosed(blocker, h, stop == eof, content)
         }}
    end
  end

  # Defense in depth: an unclosed HTML comment or `%%` comment runs to EOF and swallows every heading after it. When that is WHY this
  # section reaches EOF (the swallowed text holds a heading that would have
  # ended it), flag it so a write refuses instead of deleting or misplacing
  # what the block ate. An unclosed block with no such heading after it is
  # harmless to this section and is not flagged.
  defp unclosed({:comment, at}, h, true, content) when at >= h.line do
    rest = content |> String.split("\n") |> Enum.drop(at + 1) |> Enum.join("\n")
    if Enum.any?(scan(rest).headings, &(&1.level <= h.level)), do: at
  end

  defp unclosed(_blocker, _h, _at_eof, _content), do: nil

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
  #
  # "start" never depends on `stop`, so it's unaffected by an unclosed block
  # further down; "end" does depend on it (it back-scans from `e`), so it
  # refuses rather than risk inserting past content the block ate.
  @spec insert(String.t(), String.t(), 1..6, String.t(), String.t()) ::
          {:ok, String.t()}
          | :error
          | {:error, {:unclosed_comment, non_neg_integer()}}
  def insert(content, heading, level, position, text) do
    with {:ok, %{start: s, stop: e, span: span} = found} <- find(content, heading, level),
         :ok <- refuse_unclosed(position, found) do
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

  defp refuse_unclosed("end", %{unclosed_comment_at: l}) when is_integer(l),
    do: {:error, {:unclosed_comment, l}}

  defp refuse_unclosed(_position, _found), do: :ok

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

  # -- Parsing --

  defp analyze(content) do
    content |> String.replace_prefix(@bom, "") |> blank_frontmatter() |> scan()
  end

  # Replaces the frontmatter block with the same number of empty lines.
  defp blank_frontmatter(text) do
    case Frontmatter.split(text) do
      {nil, _body} ->
        text

      {_block, body} ->
        prefix = binary_part(text, 0, byte_size(text) - byte_size(body))
        String.duplicate("\n", length(:binary.matches(prefix, "\n"))) <> body
    end
  end

  # `text` must already be free of BOM and frontmatter. Returns the
  # document-level headings plus the block (if any) left open at EOF.
  defp scan(text) do
    # CommonMark also ends a line at a lone "\r"; callers count lines by
    # "\n" only, so a lone "\r" becomes a space (same byte offsets).
    text = String.replace(text, ~r/\r(?!\n)/, " ")
    doc = parse(text)
    {doc, pct_open} = mask_obsidian_comments(text, doc)

    %{
      headings: for(%MDEx.Heading{} = h <- doc.nodes, do: to_heading(h)),
      blocker: if(pct_open, do: {:comment, pct_open}, else: open_block(List.last(doc.nodes)))
    }
  end

  defp parse(text), do: MDEx.parse_document!(text, @parse_opts)

  defp to_heading(%MDEx.Heading{sourcepos: %{start: {l1, _}, end: {l2, _}}} = h) do
    %{line: l1 - 1, level: h.level, text: String.trim(plain_text(h.nodes)), span: l2 - l1 + 1}
  end

  # Inline markup rendered to its text: `**B**` -> "B", `[l](u)` -> "l",
  # a code span -> its content, a soft/hard break -> " ". Raw inline HTML
  # keeps its literal (it is part of what the reader sees in the source).
  defp plain_text(nodes) do
    Enum.map_join(nodes, fn
      %{literal: lit} -> lit
      %MDEx.SoftBreak{} -> " "
      %MDEx.LineBreak{} -> " "
      %{nodes: children} -> plain_text(children)
      _ -> ""
    end)
  end

  # Only a TOP-level unclosed comment runs to EOF: one nested in a list item
  # or blockquote ends with its container, which a column-0 heading closes.
  defp open_block(%MDEx.HtmlBlock{block_type: 2, literal: lit, sourcepos: %{start: {l, _}}}) do
    if String.contains?(lit, "-->"), do: nil, else: {:comment, l - 1}
  end

  defp open_block(_node), do: nil

  # Obsidian `%%` comments: every `%%` outside code (a code block or an
  # inline code span, per the first parse) toggles a comment; the regions
  # are overwritten with spaces (newlines kept, so lines and byte offsets
  # do not move) and the text re-parsed. An unclosed `%%` hides everything
  # after it. Returns the re-parsed doc and the unclosed opener's line.
  #
  # ponytail: one pass. Code spans are taken from the UNmasked parse, so a
  # backtick inside a `%%` comment can still pair with one after it and hide
  # a later `%%`; fixing that needs a parse-mask-reparse loop to a fixed
  # point, add it if it ever shows up in a real note.
  defp mask_obsidian_comments(text, doc) do
    case :binary.matches(text, "%%") do
      [] ->
        {doc, nil}

      matches ->
        starts = line_starts(text)
        code = doc |> code_ranges(starts, []) |> Enum.reverse()

        case matches |> Enum.map(&elem(&1, 0)) |> outside(code, []) do
          [] ->
            {doc, nil}

          marks ->
            {masked, open_at} = mask(text, marks)
            open_line = open_at && line_of(starts, open_at)
            {parse(masked), open_line}
        end
    end
  end

  # Byte offset of the start of each line (0-indexed line -> offset).
  defp line_starts(text) do
    [0 | for({at, _} <- :binary.matches(text, "\n"), do: at + 1)] |> List.to_tuple()
  end

  defp line_of(starts, offset) do
    Enum.find(0..(tuple_size(starts) - 1)//1, fn i ->
      i + 1 == tuple_size(starts) or elem(starts, i + 1) > offset
    end)
  end

  # [{from, to}] byte ranges (to exclusive) of code, in document order.
  # sourcepos columns are 1-based BYTE columns.
  defp code_ranges(%MDEx.CodeBlock{sourcepos: %{start: {l1, _}, end: {l2, _}}}, starts, acc) do
    to = if l2 < tuple_size(starts), do: elem(starts, l2), else: :infinity
    [{elem(starts, l1 - 1), to} | acc]
  end

  defp code_ranges(%MDEx.Code{sourcepos: %{start: {l1, c1}, end: {l2, c2}}}, starts, acc) do
    [{elem(starts, l1 - 1) + c1 - 1, elem(starts, l2 - 1) + c2} | acc]
  end

  defp code_ranges(%{nodes: nodes}, starts, acc),
    do: Enum.reduce(nodes, acc, &code_ranges(&1, starts, &2))

  defp code_ranges(_node, _starts, acc), do: acc

  # Both lists are sorted: a merge walk, O(matches + ranges).
  defp outside([], _code, acc), do: Enum.reverse(acc)
  defp outside(ms, [{_from, to} | code], acc) when hd(ms) >= to, do: outside(ms, code, acc)
  defp outside([m | ms], [{from, _} | _] = code, acc) when m >= from, do: outside(ms, code, acc)
  defp outside([m | ms], code, acc), do: outside(ms, code, [m | acc])

  # Pairs the marks (open, close, open, close, ...) and blanks each pair,
  # delimiters included. An odd mark out blanks to EOF.
  defp mask(text, marks), do: mask(text, marks, 0, [])

  defp mask(text, [open, close | rest], pos, acc) do
    acc = [
      blank(binary_part(text, open, close + 2 - open)),
      binary_part(text, pos, open - pos) | acc
    ]

    mask(text, rest, close + 2, acc)
  end

  defp mask(text, [open], pos, acc) do
    tail = binary_part(text, open, byte_size(text) - open)

    {IO.iodata_to_binary(Enum.reverse([blank(tail), binary_part(text, pos, open - pos) | acc])),
     open}
  end

  defp mask(text, [], pos, acc) do
    {IO.iodata_to_binary(Enum.reverse([binary_part(text, pos, byte_size(text) - pos) | acc])),
     nil}
  end

  defp blank(part) do
    part
    |> String.split("\n")
    |> Enum.map_intersperse("\n", &String.duplicate(" ", byte_size(&1)))
  end
end
