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
  Parse a frontmatter YAML block into `{:ok, order, values, degraded}`.
  `values` maps each encodable top-level key to the JSON-encoded string of its
  parsed value; `order` is the source order of those good keys. Keys whose
  value cannot be JSON-encoded are dropped from `order`/`values` and reported
  in `degraded` (a list of `%{key, line, snippet}`) instead.

  Returns `:error` only when the block is not YAML-map-shaped at all (whole
  block failure), never for a single bad key.
  """
  @spec parse(String.t()) ::
          {:ok, [String.t()], %{String.t() => String.t()}, [map()]} | :error
  def parse(""), do: {:ok, [], %{}, []}

  def parse(block) when is_binary(block) do
    case YamlElixir.read_from_string(block) do
      {:ok, map} when is_map(map) ->
        order = top_level_key_order(block, map)
        {values, bad_keys} = encode_values(map)
        degraded = Enum.map(bad_keys, &degraded_entry(&1, block))
        # Good keys keep source order; bad keys are dropped from `values`/
        # `order` but preserved via `degraded` (raw passthrough is Task 3).
        good_order = Enum.filter(order, &Map.has_key?(values, &1))
        {:ok, good_order, values, degraded}

      _ ->
        :error
    end
  end

  # Best-effort source location + raw slice for a top-level key that failed
  # to encode. Falls back to the bare key when the source line can't be
  # found (e.g. a key that only exists after YAML alias/anchor expansion).
  # A top-level YAML key can itself be a non-binary (flow-style complex key
  # like `[a, b]:`). Regex.escape/1 only accepts binaries, so guard first to
  # keep parse/1 total: report the inspected key, no source line.
  defp degraded_entry(key, _block) when not is_binary(key) do
    %{key: inspect(key), line: nil, snippet: inspect(key)}
  end

  defp degraded_entry(key, block) do
    lines = String.split(block, "\n")
    idx = Enum.find_index(lines, fn l -> Regex.match?(~r/^#{Regex.escape(key)}\s*:/, l) end)

    {line, snippet} =
      case idx do
        nil -> {nil, key}
        i -> {i + 1, Enum.at(lines, i)}
      end

    %{key: key, line: line, snippet: snippet}
  end

  # Encode each key's value to a JSON string. Total: a value (or exotic key inside
  # a nested map) that Jason cannot encode is COLLECTED into bad_keys instead of
  # raising or aborting. Returns {values, bad_keys}.
  # Values are deep-sorted before encoding so nested-map keys are canonical
  # (lexicographic, matching JS JSON.stringify with sorted keys in the plugin).
  @doc false
  def encode_values(map) do
    Enum.reduce(map, {%{}, []}, fn {k, v}, {values, bad} ->
      case safe_encode(v) do
        {:ok, json_str} -> {Map.put(values, k, json_str), bad}
        :error -> {values, [k | bad]}
      end
    end)
    |> then(fn {values, bad} -> {values, Enum.reverse(bad)} end)
  end

  # Deep-sort then JSON-encode a value. Jason.encode/1 returns {:error,_} for
  # some terms but RAISES for others (e.g. a charlist/tuple map KEY ->
  # List.to_string/Protocol.UndefinedError); deep_sort/1 also raises on a
  # non-binary map key. deep_sort MUST run inside this rescue so its raise is
  # trapped too, keeping the codec total.
  defp safe_encode(term) do
    case Jason.encode(deep_sort(term)) do
      {:ok, s} -> {:ok, s}
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  end

  # Recursively sort map keys for canonical JSON encoding. Arrays keep their
  # order. Scalars (string, number, bool, nil) are returned as-is. Unencodable
  # values (e.g. tuples) pass through unchanged so Jason.encode still returns
  # {:error, _} on them, routing the key into bad_keys via safe_encode/1.
  defp deep_sort(value) when is_map(value) do
    # A non-binary map key (e.g. a charlist from exotic YAML like
    # `date:YYYY-MM-DD`) is not a valid JSON object key. Jason.OrderedObject
    # would silently coerce it to a string, hiding the bad term. Raise instead
    # so safe_encode/1 traps it and collects the key into bad_keys.
    unless Enum.all?(value, fn {k, _} -> is_binary(k) end) do
      raise ArgumentError, "non-binary map key is not JSON-encodable"
    end

    Jason.OrderedObject.new(
      value
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} -> {k, deep_sort(v)} end)
    )
  end

  defp deep_sort(value) when is_list(value), do: Enum.map(value, &deep_sort/1)

  defp deep_sort(value), do: value

  @doc """
  Render ordered keys and JSON-encoded values into a YAML block (no fences).
  Empty inputs yield "". Output parses back to the same values (self-idempotent).

  Each value in `values` is a JSON string (as produced by `parse/1`); it is
  decoded before handing to the YAML emitter so the output is canonical YAML,
  not a string-of-JSON-literal.

  Y.Map values are client-controlled: a buggy or hostile peer can store a value
  that cannot be YAML-serialized (e.g. a Yex container-ref struct). This function
  degrades gracefully rather than raising, keeping emit/2 total — every checkpoint
  and REST write projects through emit, so a single unserializable value would
  otherwise brick the note.
  """
  @spec emit([String.t()], %{String.t() => term()}) :: String.t()
  def emit([], _values), do: ""

  def emit(order, values) when is_list(order) and is_map(values) do
    order
    |> Enum.filter(&Map.has_key?(values, &1))
    |> Enum.map_join("", fn key ->
      decoded = decode_value(values[key])

      try do
        Ymlr.document!(%{key => decoded}, sort_maps: false)
        |> String.replace_prefix("---\n", "")
      rescue
        # Last resort for values Ymlr cannot serialize (e.g. Yex container
        # refs): degrade to the inspected form rather than bricking the note.
        _ -> "#{key}: #{inspect(decoded)}\n"
      end
    end)
    |> ensure_trailing_newline()
  end

  # Y.Map values are client-controlled: a buggy or hostile peer can store a
  # non-JSON string (or a non-string). Degrading to the raw value keeps emit/2
  # total — a decode raise here would brick the note (every checkpoint and REST
  # write projects through emit).
  defp decode_value(v) when is_binary(v) do
    case Jason.decode(v) do
      {:ok, decoded} -> decoded
      {:error, _} -> v
    end
  end

  defp decode_value(v), do: v

  defp ensure_trailing_newline(""), do: ""

  defp ensure_trailing_newline(s) do
    if String.ends_with?(s, "\n"), do: s, else: s <> "\n"
  end

  @doc "Assemble full note plaintext from frontmatter parts and body."
  @spec project([String.t()], %{String.t() => String.t()}, String.t()) :: String.t()
  def project([], _values, body), do: body

  def project(order, values, body) when is_binary(body) do
    case emit(order, values) do
      "" -> body
      block -> "---\n" <> block <> "---\n" <> body
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
