defmodule Engram.Links.Parser do
  @moduledoc """
  Pure extraction of Obsidian-style wikilinks/embeds from plaintext markdown.
  Positions are byte offsets into the ORIGINAL content (stable for snippet
  reconstruction), which is why exclusion works by range-filtering rather than
  stripping (stripping would shift every downstream offset). For invalid-UTF-8
  input, positions are byte offsets into the scrubbed content (what any reader
  renders).
  """

  alias Engram.Notes.Helpers

  # `!` optional (embed), lazy target up to `]]`; `u` flag is load-bearing (#741).
  @link_re ~r/(!?)\[\[([^\]\[]+?)\]\]/u

  # Ranges to exclude: fenced code, inline code. Frontmatter handled separately.
  @exclusion_res [~r/```.*?```/su, ~r/~~~.*?~~~/su, ~r/`[^`\n]*`/u]
  @frontmatter_re ~r/\A---\s*\n.*?\n---\s*\n/su

  @spec extract(String.t()) :: [map()]
  def extract(content) when is_binary(content) do
    do_extract(if String.valid?(content), do: content, else: Helpers.scrub_utf8(content, :write))
  end

  defp do_extract(content) do
    excluded = exclusion_ranges(content)

    @link_re
    |> Regex.scan(content, return: :index)
    |> Enum.flat_map(fn [{start, _len}, {_, bang_len}, {inner_start, inner_len}] ->
      inner = binary_part(content, inner_start, inner_len)

      case parse_inner(inner) do
        nil ->
          []

        parsed ->
          {t_start, t_len} = target_span(inner, inner_start)

          [
            Map.merge(parsed, %{
              link_type: link_type(bang_len),
              position: start,
              target_start: t_start,
              target_len: t_len
            })
          ]
      end
    end)
    |> Enum.reject(fn %{position: pos} -> in_ranges?(pos, excluded) end)
  end

  # Byte span of the TRIMMED target within the original (scrubbed) content.
  # Mirrors parse_inner/1's split order: first `|` bounds the body, first `#`
  # in the body bounds the target. do_extract/1 runs on already-scrubbed
  # content, so clean/1's scrub inside parse_inner is an identity there and
  # `binary_part(content, target_start, target_len) == parsed.target` holds.
  defp target_span(inner, inner_start) do
    body =
      case :binary.match(inner, "|") do
        {i, _} -> binary_part(inner, 0, i)
        :nomatch -> inner
      end

    target_raw =
      case :binary.match(body, "#") do
        {i, _} -> binary_part(body, 0, i)
        :nomatch -> body
      end

    lead = byte_size(target_raw) - byte_size(String.trim_leading(target_raw))
    trimmed = String.trim(target_raw)
    {inner_start + lead, byte_size(trimmed)}
  end

  defp link_type(0), do: "wikilink"
  defp link_type(_), do: "embed"

  defp parse_inner(inner) do
    {body, alias_} =
      case String.split(inner, "|", parts: 2) do
        [body] -> {body, nil}
        [body, a] -> {body, clean(a)}
      end

    {target, anchor} =
      case String.split(body, "#", parts: 2) do
        [t] -> {clean(t), nil}
        [t, an] -> {clean(t), clean(an)}
      end

    if is_nil(target) do
      nil
    else
      %{target: target, alias: alias_, anchor: anchor}
    end
  end

  defp clean(s) do
    case s |> String.trim() |> Helpers.scrub_utf8(:write) do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp exclusion_ranges(content) do
    fm =
      case Regex.run(@frontmatter_re, content, return: :index) do
        [{0, len} | _] -> [{0, len}]
        _ -> []
      end

    code =
      Enum.flat_map(@exclusion_res, fn re ->
        re |> Regex.scan(content, return: :index) |> Enum.map(fn [{s, l} | _] -> {s, l} end)
      end)

    fm ++ code
  end

  defp in_ranges?(pos, ranges),
    do: Enum.any?(ranges, fn {s, l} -> pos >= s and pos < s + l end)
end
