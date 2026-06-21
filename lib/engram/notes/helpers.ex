defmodule Engram.Notes.Helpers do
  @moduledoc """
  Pure functions for extracting metadata from note content and paths.
  No DB access — safe to call anywhere.
  """

  @frontmatter_re ~r/\A---\n(.*?)\n---/s
  @heading_re ~r/^#\s+(.+)$/m

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
    case Regex.run(~r/^tags:\s*(.+)$/m, fm, capture: :all_but_first) do
      [raw] -> {:ok, parse_tag_value(String.trim(raw))}
      _ -> :error
    end
  end

  defp parse_tag_value("[]"), do: []

  defp parse_tag_value("[" <> rest) do
    # YAML inline list: [tag1, tag2]
    rest
    |> String.trim_trailing("]")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_tag_value(raw) do
    # Comma-separated string: tag1, tag2
    raw
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
