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

  @type heading :: %{line: non_neg_integer(), level: 1..6, text: String.t(), span: 1..2}

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
  # never mistaken for one.
  @setext_re ~r/^ {0,3}(=+|-+)[ \t]*\r?$/

  @spec headings(String.t()) :: [heading()]
  def headings(content) do
    scan_content = String.replace_prefix(content, @bom, "")

    {found, _fence, _prev} =
      scan_content
      |> String.split("\n")
      |> Enum.with_index()
      |> Enum.drop(frontmatter_lines(content))
      |> Enum.reduce({[], nil, nil}, &scan/2)

    Enum.reverse(found)
  end

  @spec find(String.t(), String.t(), 1..6 | nil) ::
          {:ok, %{start: non_neg_integer(), stop: non_neg_integer(), span: 1..2}} | :error
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
      text = text |> String.trim_trailing("\n") |> match_eol(content)

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

      {:ok, lines |> List.insert_at(at, text) |> Enum.join("\n")}
    end
  end

  # Converts `text`'s line endings to CRLF when `source` (the note being
  # edited) uses CRLF, so a write never leaves a mix behind. `source` lines
  # already end each non-final line in `\r` (the note's own bytes); we mirror
  # that shape here (`\r` appended per line, joined with bare `\n`) so the
  # inserted block is uniform with its neighbors once the caller joins
  # everything back together with `\n`.
  @spec match_eol(String.t(), String.t()) :: String.t()
  def match_eol(text, source) do
    if String.contains?(source, "\r\n") do
      text
      |> String.split("\n")
      |> Enum.map_join("\n", &(String.trim_trailing(&1, "\r") <> "\r"))
    else
      text
    end
  end

  # Not currently fenced: an opening fence starts one; otherwise look for an
  # ATX or setext heading (scan_open/4). Currently fenced: only a closing
  # fence (same char, no info string, length >= opener) ends it; everything
  # else, including a `---`/`===` line, is invisible while inside the fence.
  defp scan({line, i}, {acc, nil, prev}) do
    case fence_open(line) do
      nil -> scan_open(line, i, acc, prev)
      marker -> {acc, marker, nil}
    end
  end

  defp scan({line, _i}, {acc, fence, _prev}) do
    case fence_close(line) do
      nil -> {acc, fence, nil}
      marker -> if closes?(fence, marker), do: {acc, nil, nil}, else: {acc, fence, nil}
    end
  end

  defp scan_open(line, i, acc, prev) do
    case Regex.run(@heading_re, line) do
      [_, hashes] -> {[atx(i, hashes, "") | acc], nil, nil}
      [_, hashes, text] -> {[atx(i, hashes, text) | acc], nil, nil}
      nil -> scan_text(line, i, acc, prev)
    end
  end

  defp atx(i, hashes, text), do: %{line: i, level: String.length(hashes), text: text, span: 1}

  # A setext heading only forms when the immediately preceding line was a
  # plain paragraph line (`prev` is `{:para, ...}`). A blank line, an ATX
  # heading, or a fence (open or close) all reset `prev` to `nil`, so a `---`
  # right after any of those is a thematic break, not a heading -- and it
  # does NOT become a new paragraph candidate itself, so two underline-shaped
  # lines in a row can't chain into a heading either.
  defp scan_text(line, i, acc, prev) do
    cond do
      String.trim(line) == "" ->
        {acc, nil, nil}

      (level = setext_level(line)) != nil ->
        case prev do
          {:para, pidx, ptext} ->
            {[%{line: pidx, level: level, text: ptext, span: 2} | acc], nil, nil}

          _ ->
            {acc, nil, nil}
        end

      true ->
        {acc, nil, {:para, i, String.trim(line)}}
    end
  end

  defp setext_level(line) do
    case Regex.run(@setext_re, line) do
      [_, run] -> if String.starts_with?(run, "="), do: 1, else: 2
      nil -> nil
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
