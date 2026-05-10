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

  @doc """
  Extracts tags from YAML frontmatter. Returns [] if none found.
  """
  @spec extract_tags(String.t()) :: [String.t()]
  def extract_tags(content) do
    with fm when fm != nil <- extract_frontmatter(content),
         {:ok, tags} <- parse_frontmatter_tags(fm) do
      tags
    else
      _ -> []
    end
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
