defmodule Engram.MCP.Sections do
  @moduledoc """
  Markdown heading lookup shared by edit_note (replace_section,
  insert_section) and get_notes (section, outline). Pure: string in, data out.

  Lines inside the frontmatter block or a fenced code block are never
  headings, so a YAML `# comment` or a shell `# comment` in a fence can
  neither be matched nor end a section early.
  """

  alias Engram.Notes.Frontmatter

  @type heading :: %{line: non_neg_integer(), level: 1..6, text: String.t()}

  # `\#` because `#{` would interpolate. Leading `\s{0,3}` mirrors CommonMark:
  # at most 3 spaces of indent, 4+ is an indented code line, not a heading
  # (same bound as `@fence_re` below). The trailing `(?:\s+#+)?` strips an
  # optional ATX closing sequence ("## Title ##" -> "Title"); it must be
  # preceded by whitespace, so "## Title##" keeps the hashes as text. Trailing
  # `\s*` also eats a CRLF `\r`.
  @heading_re ~r/^\s{0,3}(\#{1,6})(?:\s+(.*?))?(?:\s+#+)?\s*$/
  @fence_re ~r/^\s{0,3}(`{3,}|~{3,})/

  @spec headings(String.t()) :: [heading()]
  def headings(content) do
    {found, _open} =
      content
      |> String.split("\n")
      |> Enum.with_index()
      |> Enum.drop(frontmatter_lines(content))
      |> Enum.reduce({[], nil}, &scan/2)

    Enum.reverse(found)
  end

  @spec find(String.t(), String.t(), 1..6 | nil) ::
          {:ok, %{start: non_neg_integer(), stop: non_neg_integer()}} | :error
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

        {:ok, %{start: h.line, stop: stop}}
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

  # "start": directly under the heading line. "end": after the section's last
  # non-blank line, so blank lines before the next heading stay where they are.
  @spec insert(String.t(), String.t(), 1..6, String.t(), String.t()) :: {:ok, String.t()} | :error
  def insert(content, heading, level, position, text) do
    with {:ok, %{start: s, stop: e}} <- find(content, heading, level) do
      lines = String.split(content, "\n")

      at =
        case position do
          "start" ->
            s + 1

          "end" ->
            # The heading line itself is non-blank, so this always finds one.
            back =
              lines
              |> Enum.slice(s, e - s)
              |> Enum.reverse()
              |> Enum.find_index(&(String.trim(&1) != ""))

            e - back
        end

      {:ok, lines |> List.insert_at(at, String.trim_trailing(text, "\n")) |> Enum.join("\n")}
    end
  end

  defp scan({line, i}, {acc, open}) do
    case {open, fence(line)} do
      {nil, nil} -> {heading(acc, line, i), nil}
      {nil, marker} -> {acc, marker}
      {open, nil} -> {acc, open}
      {open, marker} -> if closes?(open, marker), do: {acc, nil}, else: {acc, open}
    end
  end

  defp heading(acc, line, i) do
    # No String.trim_leading/1 here: @heading_re bounds the indent itself
    # (0-3 whitespace chars), so a 4+-space line correctly fails to match.
    case Regex.run(@heading_re, line) do
      [_, hashes] -> [%{line: i, level: String.length(hashes), text: ""} | acc]
      [_, hashes, text] -> [%{line: i, level: String.length(hashes), text: text} | acc]
      nil -> acc
    end
  end

  defp fence(line) do
    case Regex.run(@fence_re, line) do
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
