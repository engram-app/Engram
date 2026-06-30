defmodule Engram.Notes.Frontmatter do
  @moduledoc """
  Pure codec between a note's YAML frontmatter and the structured form stored in
  the CRDT `Y.Map`. No Yex here: split/parse/emit/project are total functions on
  strings and maps so they are trivially testable and reusable.
  """

  @fence "---"
  @fence_line_pattern ~r/\n---[ \t]*\r?\n/
  @fence_eof_pattern ~r/\n---[ \t]*\r?$/

  @doc """
  Split a note into its frontmatter YAML block (text between the fences, without
  the `---` lines) and its body. Returns `{nil, full_text}` when there is no
  well-formed leading frontmatter (must start at byte 0 and have a closing fence).
  """
  @spec split(String.t()) :: {String.t() | nil, String.t()}
  def split(plaintext) when is_binary(plaintext) do
    case plaintext do
      @fence <> <<?\n, rest::binary>> ->
        case rest do
          @fence <> <<?\n, body::binary>> ->
            # Empty frontmatter: --- immediately followed by ---
            {"", body}

          _ ->
            # Look for closing fence preceded by newline (with optional trailing whitespace/CR)
            case Regex.split(@fence_line_pattern, rest, parts: 2) do
              [block, body] ->
                {block <> "\n", body}

              # No closing fence with trailing newline; try fence at EOF
              [_only] ->
                split_trailing(rest, plaintext)
            end
        end

      _ ->
        {nil, plaintext}
    end
  end

  defp split_trailing(rest, original) do
    case Regex.split(@fence_eof_pattern, rest, parts: 2) do
      [block, ""] -> {block <> "\n", ""}
      _ -> {nil, original}
    end
  end

  @doc """
  Parse a frontmatter YAML block into `{:ok, order, values}` where `values` maps
  each top-level key to the JSON-encoded string of its parsed value, and `order` is
  the source key order. Returns `:error` on malformed YAML or if any value cannot
  be JSON-encoded.
  """
  @spec parse(String.t()) :: {:ok, [String.t()], %{String.t() => String.t()}} | :error
  def parse(""), do: {:ok, [], %{}}

  def parse(block) when is_binary(block) do
    case YamlElixir.read_from_string(block) do
      {:ok, map} when is_map(map) ->
        order = top_level_key_order(block, map)

        case encode_values(map) do
          {:ok, values} -> {:ok, order, values}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  # Encode all map values to JSON strings. Returns {:ok, values_map} on success,
  # :error if any value cannot be encoded (unencodable exotic types like tuples).
  @doc false
  def encode_values(map) do
    result =
      Enum.reduce_while(map, %{}, fn {k, v}, acc ->
        case Jason.encode(v) do
          {:ok, json_str} -> {:cont, Map.put(acc, k, json_str)}
          {:error, _} -> {:halt, :error}
        end
      end)

    case result do
      :error -> :error
      values_map -> {:ok, values_map}
    end
  end

  # Recover source order: top-level keys appear as `key:` at column 0.
  defp top_level_key_order(block, map) do
    block
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      case Regex.run(~r/^([^\s:][^:]*):/, line) do
        [_, key] -> if Map.has_key?(map, key) and key not in acc, do: [key | acc], else: acc
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end
end
