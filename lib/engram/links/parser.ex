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
        nil -> []
        parsed -> [Map.merge(parsed, %{link_type: link_type(bang_len), position: start})]
      end
    end)
    |> Enum.reject(fn %{position: pos} -> in_ranges?(pos, excluded) end)
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

  defp clean(nil), do: nil

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
