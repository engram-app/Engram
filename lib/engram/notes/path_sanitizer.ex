defmodule Engram.Notes.PathSanitizer do
  @moduledoc """
  Sanitizes note paths for safe filesystem and database storage.

  Rules applied (in order), repeated until the path stops changing so that
  `sanitize(sanitize(x)) == sanitize(x)`:
  1. Strip null bytes
  2. URL-decode percent-encoded characters (catches %2F traversal tricks)
  3. Strip illegal filesystem chars: \\ : * ? < > " |
  4. Split on `/`, process each segment independently
  5. Drop traversal segments (`..`) and no-op segments (`.`, empty)
  6. Strip leading/trailing spaces per segment
  7. Collapse multiple spaces within a segment
  8. Truncate each segment to 255 bytes (filesystem limit)
  9. Rejoin remaining segments

  Idempotence matters because callers re-sanitize: `sanitize_target/1` checks a
  move target, then the per-item mover sanitizes each joined path again. With a
  single pass `%252e%252e` cleared the first check as `%2e%2e` and became `..`
  on the second. After `@max_decode_passes` passes that still change the path
  (a deeply nested encoding), every `%` is dropped so no further decode can
  happen; without `%` each changing pass only shortens the path, so it ends.
  """

  # Characters illegal on iOS, Android, and Windows filesystems
  @illegal_chars ~r/[\\:*?<>"|]/

  # Legit paths settle in one or two passes; this only bounds a hostile nesting.
  @max_decode_passes 8

  @doc """
  Sanitizes a note path. Returns the cleaned path string.
  """
  @spec sanitize(String.t()) :: String.t()
  def sanitize(""), do: ""

  def sanitize(path), do: fixed_point(path, @max_decode_passes)

  defp fixed_point(path, passes_left) do
    case sanitize_pass(path) do
      ^path -> path
      next when passes_left > 0 -> fixed_point(next, passes_left - 1)
      next -> next |> String.replace("%", "") |> fixed_point(0)
    end
  end

  defp sanitize_pass(path) do
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
