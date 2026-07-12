defmodule Engram.Notes.Frontmatter do
  @moduledoc """
  Pure codec between a note's YAML frontmatter and the structured form stored in
  the CRDT `Y.Map`. No Yex here: split/parse/emit/project are total functions on
  strings and maps so they are trivially testable and reusable.
  """

  @fence "---"
  @fence_line_pattern ~r/\n---[ \t]*\r?\n/
  @fence_eof_pattern ~r/\n---[ \t]*\r?$/

  # A column-0 `key:` line. Same shape top_level_key_order/2 keys on.
  @top_key_pattern ~r/^([^\s:][^:]*):/

  # Marker envelope for a degraded key's raw source, preserved verbatim so
  # emit re-renders it byte-for-byte instead of dropping it.
  @raw_key "__engram_raw__"

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

  @doc """
  Build the stored/echoed `parse_reason` from a degraded-keys list (`parse/1`'s
  4th element). `nil` when the list is empty (clean parse). Reports the FIRST
  degraded key's detail; a note with several bad keys still needs only one
  actionable pointer. Reason shape is pinned (string keys, jsonb-storable):
  `%{"code", "message", "detail" => %{"key", "line", "snippet"}}`.
  """
  @spec reason_for([map()]) :: map() | nil
  def reason_for([]), do: nil

  def reason_for([%{key: key, line: line, snippet: snippet} | _] = degraded) do
    %{
      "code" => "frontmatter_unparseable_key",
      "message" => degraded_key_message(degraded),
      "detail" => %{"key" => key, "line" => line, "snippet" => snippet}
    }
  end

  defp degraded_key_message([_]), do: "A frontmatter key could not be parsed as YAML."

  defp degraded_key_message(degraded) do
    "#{length(degraded)} frontmatter keys could not be parsed as YAML."
  end

  @doc """
  Build the `parse_reason` for the whole-block `parse/1` `:error` case (the
  block isn't YAML-map-shaped at all, e.g. `date:YYYY-MM-DD` with no space).
  Distinct code from `reason_for/1`'s per-key case: there is no single bad
  key to point at, so `detail.key` is nil and the snippet is the block's
  first line.
  """
  @spec invalid_yaml_reason(String.t()) :: %{
          String.t() => String.t() | %{String.t() => String.t() | pos_integer() | nil}
        }
  def invalid_yaml_reason(block) when is_binary(block) do
    first_line = block |> String.split("\n", parts: 2) |> hd()

    %{
      "code" => "frontmatter_invalid_yaml",
      "message" => "The note's frontmatter is not valid YAML.",
      "detail" => %{"key" => nil, "line" => 1, "snippet" => truncate_snippet(first_line)}
    }
  end

  @doc "Wrap a degraded key's raw source so emit/2 re-renders it verbatim."
  @spec raw_marker(String.t()) :: String.t()
  def raw_marker(raw) when is_binary(raw), do: Jason.encode!(%{@raw_key => raw})

  @doc """
  Unwrap a raw-passthrough marker. `{:ok, raw}` for a marker produced by
  `raw_marker/1`; `:error` for any other string (a normal JSON value).
  """
  @spec raw_from_marker(String.t()) :: {:ok, String.t()} | :error
  def raw_from_marker(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{@raw_key => raw}} when is_binary(raw) -> {:ok, raw}
      _ -> :error
    end
  end

  def raw_from_marker(_), do: :error

  @doc """
  Parse a frontmatter block for CRDT ingest, preserving degraded keys as raw
  passthrough so nothing is lost when the Y.Map re-emits the note.

  Returns `{:ok, order, values}` where `order` is the full source order of all
  top-level keys and `values` maps each key to either its JSON-encoded value
  (good keys) or a `raw_marker/1` of its verbatim source span (degraded keys).

  Returns `:error` when the block is not a YAML map, OR when a degraded key's
  raw source span cannot be captured losslessly (its column-0 line-tiling is
  ambiguous with the parsed key set, e.g. a non-binary top-level key or a
  multi-line flow value with an unindented continuation). The caller then
  falls back to storing the whole text as body, which is also lossless.
  """
  @spec parse_for_ingest(String.t()) ::
          {:ok, [String.t()], %{String.t() => String.t()}} | :error
  def parse_for_ingest(""), do: {:ok, [], %{}}

  def parse_for_ingest(block) when is_binary(block) do
    case YamlElixir.read_from_string(block) do
      {:ok, map} when is_map(map) ->
        {values, bad_keys} = encode_values(map)

        # A GOOD value can encode to JSON that raw_from_marker/1 mistakes for a
        # passthrough marker (a map merely containing @raw_key). emit/2 would
        # then render its inner raw and DROP the key. Route those through the
        # same verbatim span-passthrough so they round-trip exactly. No marker
        # format can disambiguate the exact single-key collision, so this is
        # the robust fix, not tightening the pattern.
        colliding = for {k, v} <- values, match?({:ok, _}, raw_from_marker(v)), do: k
        passthrough_keys = bad_keys ++ colliding

        if passthrough_keys == [] do
          # No degraded/colliding keys: keep the existing structured behaviour.
          {:ok, top_level_key_order(block, map), values}
        else
          ingest_with_passthrough(block, map, values, passthrough_keys)
        end

      _ ->
        :error
    end
  end

  # Passthrough keys present (degraded and/or marker-colliding): require an
  # exact column-0 line-tiling of the block so each key's raw source span is
  # captured byte-for-byte, then store each as a verbatim raw marker.
  defp ingest_with_passthrough(block, map, values, passthrough_keys) do
    case raw_spans(block, map) do
      {:ok, order, spans} ->
        merged =
          Enum.reduce(passthrough_keys, values, fn key, acc ->
            case Map.fetch(spans, key) do
              {:ok, raw} -> Map.put(acc, key, raw_marker(raw))
              :error -> acc
            end
          end)

        # Every passthrough key must have a captured span, else it would vanish
        # (degraded) or stay a false-marker good value (colliding). Either way
        # fall back to the lossless whole-text-as-body path.
        if Enum.all?(passthrough_keys, &match?({:ok, _}, Map.fetch(spans, &1))),
          do: {:ok, order, merged},
          else: :error

      :error ->
        :error
    end
  end

  # Tile the block by its column-0 `key:` lines. Returns `{:ok, order, spans}`
  # only when that tiling is a bijection with the parsed map's keys (source
  # order preserved), so each key owns exactly the lines from its own line up
  # to the next key's line: a lossless span. Any ambiguity returns :error.
  defp raw_spans(block, map) do
    lines = String.split(block, "\n")

    keyed =
      lines
      |> Enum.with_index()
      |> Enum.flat_map(fn {line, i} ->
        case Regex.run(@top_key_pattern, line) do
          [_, key] -> [{i, key}]
          _ -> []
        end
      end)

    col0_keys = Enum.map(keyed, fn {_i, k} -> k end)

    if tileable?(keyed, col0_keys, map) do
      idxs = Enum.map(keyed, fn {i, _k} -> i end)
      bounds = Enum.zip(keyed, tl(idxs) ++ [length(lines)])

      spans =
        Map.new(bounds, fn {{i, key}, next} ->
          # Strip only the single structural newline the trailing "" split
          # element added, so an intentional blank line inside the value
          # survives. emit/2 re-adds exactly one via ensure_trailing_newline/1.
          raw =
            lines
            |> Enum.slice(i, next - i)
            |> Enum.join("\n")
            |> String.replace_suffix("\n", "")

          {key, raw}
        end)

      {:ok, col0_keys, spans}
    else
      :error
    end
  end

  # Exact tiling: first line is a key, no duplicate column-0 keys, and the
  # column-0 key set is exactly the parsed map's key set (so no map key lives
  # only in an alias/anchor, and no value's continuation masquerades as a key).
  defp tileable?(keyed, col0_keys, map) do
    keyed != [] and
      elem(hd(keyed), 0) == 0 and
      length(Enum.uniq(col0_keys)) == length(col0_keys) and
      length(col0_keys) == map_size(map) and
      MapSet.new(col0_keys) == MapSet.new(Map.keys(map))
  end

  # Best-effort source location + raw slice for a top-level key that failed
  # to encode. Falls back to the bare key when the source line can't be
  # found (e.g. a key that only exists after YAML alias/anchor expansion).
  # A top-level YAML key can itself be a non-binary (flow-style complex key
  # like `[a, b]:`). Regex.escape/1 only accepts binaries, so guard first to
  # keep parse/1 total: report the inspected key, no source line.
  defp degraded_entry(key, _block) when not is_binary(key) do
    %{key: inspect(key), line: nil, snippet: truncate_snippet(inspect(key))}
  end

  defp degraded_entry(key, block) do
    lines = String.split(block, "\n")
    idx = Enum.find_index(lines, fn l -> Regex.match?(~r/^#{Regex.escape(key)}\s*:/, l) end)

    {line, snippet} =
      case idx do
        nil -> {nil, key}
        i -> {i + 1, Enum.at(lines, i)}
      end

    %{key: key, line: line, snippet: truncate_snippet(snippet)}
  end

  # `snippet` is a raw frontmatter source line for a diagnostic reason
  # (`parse_reason`), re-echoed on every /sync/changes fetch for the note. A
  # pathologically long single-line value must not balloon that jsonb column
  # or the feed payload. This ONLY bounds the diagnostic copy: the verbatim
  # raw span used for lossless passthrough (raw_marker/raw_spans, Task 3)
  # is a separate value built from the same source line, not from this
  # truncated one, so round-trip fidelity is unaffected.
  @snippet_max_length 200
  defp truncate_snippet(snippet), do: String.slice(snippet, 0, @snippet_max_length)

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
    |> Enum.map_join("", fn key -> emit_key(key, values[key]) end)
    |> ensure_trailing_newline()
  end

  # A degraded key is re-rendered from its verbatim source span (never via
  # Ymlr, which would canonicalize/lose it); a good key is decoded then emitted
  # as canonical YAML. ensure_trailing_newline/1 normalizes the final newline
  # for both so a marker with or without a trailing newline round-trips.
  defp emit_key(key, value) do
    case raw_from_marker(value) do
      {:ok, raw} ->
        ensure_trailing_newline(raw)

      :error ->
        decoded = decode_value(value)

        try do
          Ymlr.document!(%{key => decoded}, sort_maps: false)
          |> String.replace_prefix("---\n", "")
        rescue
          # Last resort for values Ymlr cannot serialize (e.g. Yex container
          # refs): degrade to the inspected form rather than bricking the note.
          _ -> "#{key}: #{inspect(decoded)}\n"
        end
    end
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
