defmodule Engram.Notes.PathSanitizer do
  @moduledoc """
  Sanitizes note paths for safe filesystem and database storage.

  Rules applied (in order):
  1. Strip null bytes
  2. URL-decode percent-encoded characters (catches %2F traversal tricks)
  3. Strip illegal filesystem chars: \\ : * ? < > " |
  4. Split on `/`, process each segment independently
  5. Drop traversal segments (`..`) and no-op segments (`.`, empty)
  6. Strip leading/trailing spaces per segment
  7. Collapse multiple spaces within a segment
  8. Truncate each segment to 255 bytes (filesystem limit)
  9. Rejoin remaining segments
  """

  # Characters illegal on iOS, Android, and Windows filesystems
  @illegal_chars ~r/[\\:*?<>"|]/

  @doc """
  Sanitizes a note path. Returns the cleaned path string.
  """
  @spec sanitize(String.t()) :: String.t()
  def sanitize(""), do: ""

  def sanitize(path) do
    path
    |> String.replace("\x00", "")
    |> URI.decode()
    |> String.replace(@illegal_chars, "")
    |> String.trim_leading("/")
    |> String.split("/")
    |> Enum.map(&clean_segment/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("/")
  end

  @doc """
  Sanitizes a rename/move TARGET folder. The vault root (`""` or `"/"`)
  passes through as `""`; a non-empty target that cleans to `""` (`..`,
  `%2e%2e`) is `{:error, :invalid_path}` rather than a silent move to root.
  """
  @spec sanitize_target(String.t()) :: {:ok, String.t()} | {:error, :invalid_path}
  def sanitize_target(path) do
    case {sanitize(path), String.trim(path)} do
      {"", root} when root in ["", "/"] -> {:ok, ""}
      {"", _} -> {:error, :invalid_path}
      {clean, _} -> {:ok, clean}
    end
  end

  defp clean_segment(segment) do
    segment
    |> String.trim()
    |> String.replace("..", "")
    |> collapse_spaces()
    |> truncate_segment(255)
    |> reject_traversal()
  end

  defp collapse_spaces(s), do: Regex.replace(~r/ {2,}/, s, " ")

  defp truncate_segment(s, max_bytes) do
    if byte_size(s) <= max_bytes do
      s
    else
      # Truncate at a safe UTF-8 codepoint boundary
      s
      |> String.codepoints()
      |> Enum.reduce_while({"", 0}, fn cp, {acc, total} ->
        new_total = total + byte_size(cp)

        if new_total <= max_bytes,
          do: {:cont, {acc <> cp, new_total}},
          else: {:halt, {acc, total}}
      end)
      |> elem(0)
    end
  end

  # Drop empty segments (from double slashes, trailing slash, etc.),
  # traversal segments (..), and no-op segments (.)
  defp reject_traversal(""), do: nil
  defp reject_traversal(".."), do: nil
  defp reject_traversal(". ."), do: nil
  defp reject_traversal("."), do: nil
  defp reject_traversal(s), do: s
end
