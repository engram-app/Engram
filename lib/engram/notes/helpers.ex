defmodule Engram.Notes.Helpers do
  @moduledoc """
  Pure functions for extracting metadata from note content and paths.
  No DB access — safe to call anywhere.
  """

  @frontmatter_re ~r/\A---\r?\n(.*?)\r?\n---/s
  @heading_re ~r/^#\s+(.+)$/m

  @doc """
  Replaces invalid UTF-8 byte sequences with the Unicode replacement
  character (U+FFFD `�`), returning a guaranteed-valid UTF-8 string.

  Note content is encrypted and stored as `bytea`, which bypasses Postgres's
  UTF-8 validation — so a client can persist invalid bytes (e.g. a multibyte
  char truncated to its lead byte). Those bytes later crash `Jason.encode`
  anywhere content reaches a JSON boundary (search responses, sync Channel
  broadcasts) with a 500. Scrubbing keeps the read/write paths total. Valid
  input is returned byte-identical (no allocation churn for the common case).
  """
  @spec scrub_utf8(String.t()) :: String.t()
  def scrub_utf8(str) when is_binary(str) do
    if String.valid?(str), do: str, else: do_scrub_utf8(str, <<>>)
  end

  defp do_scrub_utf8(<<>>, acc), do: acc

  defp do_scrub_utf8(<<cp::utf8, rest::binary>>, acc),
    do: do_scrub_utf8(rest, <<acc::binary, cp::utf8>>)

  defp do_scrub_utf8(<<_bad, rest::binary>>, acc),
    do: do_scrub_utf8(rest, <<acc::binary, "�">>)

  @doc """
  Extracts the note title from content (frontmatter > h1 heading > filename).
  """
  @spec extract_title(String.t(), String.t()) :: String.t() | nil
  def extract_title(content, path) do
    extract_frontmatter_title(content) ||
      extract_heading_title(content) ||
      filename_without_extension(path)
  end

  # Inline Obsidian tag: `#tag` or nested `#area/sub`. Must be preceded by
  # start-of-string or whitespace (so `word#x` and `https://h/#frag` are NOT
  # tags) and must start with a word char (so `# heading` — a space after the
  # hash — is NOT a tag). `{}` delimiter avoids escaping the `/`.
  @inline_tag_re ~r{(?:^|\s)#([\w][\w/-]*)}

  @doc """
  Extracts tags from a note: YAML frontmatter tags merged with inline
  `#tags` (incl. nested `#area/sub`) found in the body.

  Inline scanning skips fenced + inline code, URL fragments, and heading
  markers, and drops purely-numeric matches (`#42`) — none of which are
  tags in Obsidian. Frontmatter tags come first; duplicates are removed.
  Returns [] if none found.
  """
  @spec extract_tags(String.t()) :: [String.t()]
  def extract_tags(content) do
    frontmatter_tags = extract_frontmatter_tags(content)
    inline_tags = extract_inline_tags(content)
    Enum.uniq(frontmatter_tags ++ inline_tags)
  end

  @doc """
  Extracts the folder path (dirname) from a note path.
  Returns "" for root-level notes.
  """
  @spec extract_folder(String.t()) :: String.t()
  def extract_folder(path) do
    case String.split(path, "/") do
      [_filename] -> ""
      parts -> parts |> Enum.drop(-1) |> Enum.join("/")
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp extract_frontmatter(content) do
    case Regex.run(@frontmatter_re, content, capture: :all_but_first) do
      [fm] -> fm
      _ -> nil
    end
  end

  defp extract_frontmatter_title(content) do
    with fm when fm != nil <- extract_frontmatter(content) do
      case Regex.run(~r/^title:\s*(.+)$/m, fm, capture: :all_but_first) do
        [title] when is_binary(title) -> String.trim(title)
        _ -> nil
      end
    end
  end

  defp extract_heading_title(content) do
    # Skip past frontmatter block before searching for heading
    body = Regex.replace(@frontmatter_re, content, "")

    case Regex.run(@heading_re, body, capture: :all_but_first) do
      [heading] when is_binary(heading) -> String.trim(heading)
      _ -> nil
    end
  end

  defp filename_without_extension(path) do
    case String.split(path, "/") |> List.last() do
      nil -> ""
      filename when is_binary(filename) -> Path.rootname(filename)
    end
  end

  defp extract_frontmatter_tags(content) do
    with fm when fm != nil <- extract_frontmatter(content),
         {:ok, tags} <- parse_frontmatter_tags(fm) do
      tags
    else
      _ -> []
    end
  end

  defp extract_inline_tags(content) do
    content
    |> strip_frontmatter()
    |> strip_code()
    |> then(&Regex.scan(@inline_tag_re, &1, capture: :all_but_first))
    |> List.flatten()
    # Trim trailing separators left by e.g. `#foo/` at a word boundary.
    |> Enum.map(&Regex.replace(~r{[/-]+$}, &1, ""))
    |> Enum.reject(&(&1 == "" or numeric_tag?(&1)))
  end

  # Obsidian rejects purely-numeric tags (so `#42`, `#1/2` are not tags).
  defp numeric_tag?(tag), do: Regex.match?(~r{^[\d/_-]+$}, tag)

  defp strip_frontmatter(content), do: Regex.replace(@frontmatter_re, content, "")

  # Fenced (``` / ~~~) and inline (`…`) code spans, stripped before scanning
  # so a `#tag` written as a code example isn't indexed.
  @code_span_res [~r/```.*?```/s, ~r/~~~.*?~~~/s, ~r/`[^`\n]*`/]

  # Replace code spans with a space (not "") so a preceding word can't fuse
  # onto a following `#tag` across the removed span.
  defp strip_code(text) do
    Enum.reduce(@code_span_res, text, &Regex.replace(&1, &2, " "))
  end

  defp parse_frontmatter_tags(fm) do
    cond do
      # Block-style list: `tags:` alone on its line, items as `  - item` below.
      block = parse_block_list_tags(fm) ->
        {:ok, block}

      # Inline value on the same line: `tags: [a, b]` or `tags: a, b`.
      # `[ \t]*` (no newline) + `\S` keeps the match on the `tags:` line so it
      # never spills onto a following `- item` line.
      match = Regex.run(~r/^tags:[ \t]*(\S.*)$/m, fm, capture: :all_but_first) ->
        [raw] = match
        {:ok, parse_tag_value(String.trim(raw))}

      true ->
        :error
    end
  end

  # YAML block list under a bare `tags:` line. Returns nil when not block-style
  # so the caller falls through to inline parsing.
  defp parse_block_list_tags(fm) do
    case Regex.run(~r/^tags:[ \t]*\r?\n(.*)/ms, fm, capture: :all_but_first) do
      [rest] ->
        items =
          rest
          |> String.split("\n")
          |> Enum.take_while(&Regex.match?(~r/^\s*-\s+/, &1))
          |> Enum.map(&(&1 |> String.replace(~r/^\s*-\s+/, "") |> unquote_tag()))
          |> Enum.reject(&(&1 == ""))

        if items == [], do: nil, else: items

      _ ->
        nil
    end
  end

  # Strip surrounding matching quotes from a YAML scalar (and trim whitespace).
  defp unquote_tag(raw) do
    s = String.trim(raw)

    cond do
      String.length(s) >= 2 and String.starts_with?(s, "\"") and String.ends_with?(s, "\"") ->
        String.slice(s, 1, String.length(s) - 2)

      String.length(s) >= 2 and String.starts_with?(s, "'") and String.ends_with?(s, "'") ->
        String.slice(s, 1, String.length(s) - 2)

      true ->
        s
    end
  end

  defp parse_tag_value("[]"), do: []

  defp parse_tag_value("[" <> rest) do
    # YAML inline list: [tag1, tag2]
    rest
    |> String.trim_trailing("]")
    |> String.split(",")
    |> Enum.map(&unquote_tag/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_tag_value(raw) do
    # Comma-separated string: tag1, tag2
    raw
    |> String.split(",")
    |> Enum.map(&unquote_tag/1)
    |> Enum.reject(&(&1 == ""))
  end
end
