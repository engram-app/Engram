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
    # Content-safe: never echo the raw block text. Frontmatter values are
    # encrypted at rest and this reason is persisted PLAINTEXT + shipped on
    # /sync/changes, so a secret in a malformed value must not leak here.
    _ = block

    %{
      "code" => "frontmatter_invalid_yaml",
      "message" => "The note's frontmatter is not valid YAML.",
      "detail" => %{"key" => nil, "line" => 1, "snippet" => "<frontmatter>"}
    }
  end

  @doc """
  Parse a frontmatter block for CRDT ingest, preserving degraded keys as raw
  passthrough so nothing is lost when the Y.Map re-emits the note.

  Returns `{:ok, order, values, raws}` where `order` is the full source order
  of all top-level keys, `values` maps each GOOD key to its JSON-encoded value,
  and `raws` maps each DEGRADED key to its verbatim source span (stored out of
  band from `values`). A key appears in exactly one of `values`/`raws`. Storing
  raws out of band means `emit/3` never has to guess whether a `values` entry
  is a real value or a passthrough marker, so a normal value shaped like the old
  in-band marker can never be mis-rendered.

  Returns `:error` when the block is not a YAML map, OR when a degraded key's
  raw source span cannot be captured losslessly (its column-0 line-tiling is
  ambiguous with the parsed key set, e.g. a non-binary top-level key or a
  multi-line flow value with an unindented continuation). The caller then
  falls back to storing the whole text as body, which is also lossless.
  """
  @spec parse_for_ingest(String.t()) ::
          {:ok, [String.t()], %{String.t() => String.t()}, %{String.t() => String.t()}}
          | :error
  def parse_for_ingest(""), do: {:ok, [], %{}, %{}}

  def parse_for_ingest(block) when is_binary(block) do
    case YamlElixir.read_from_string(block) do
      {:ok, map} when is_map(map) ->
        {values, bad_keys} = encode_values(map)

        if bad_keys == [] do
          # No degraded keys: fully structured, no raw passthrough needed.
          {:ok, top_level_key_order(block, map), values, %{}}
        else
          ingest_with_passthrough(block, map, values, bad_keys)
        end

      _ ->
        :error
    end
  end

  # Degraded keys present: require an exact column-0 line-tiling of the block so
  # each key's raw source span is captured byte-for-byte, then store each in the
  # out-of-band `raws` map so emit/3 re-renders it verbatim.
  defp ingest_with_passthrough(block, map, values, passthrough_keys) do
    case raw_spans(block, map) do
      {:ok, order, spans} ->
        # Every degraded key must have a captured span, else it would vanish.
        # Fall back to the lossless whole-text-as-body path when any is missing.
        if Enum.all?(passthrough_keys, &Map.has_key?(spans, &1)) do
          raws = Map.new(passthrough_keys, fn key -> {key, Map.fetch!(spans, key)} end)
          {:ok, order, values, raws}
        else
          :error
        end

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

  # Best-effort source LOCATION for a top-level key that failed to encode.
  # `snippet` carries ONLY the key name, never the value: this entry feeds the
  # PLAINTEXT `parse_reason` column that is echoed on /sync/changes, and note
  # content is encrypted at rest, so a secret in a malformed value must not
  # leak. The verbatim raw span used for lossless passthrough is captured
  # separately (raw_spans/2), not from this diagnostic entry.
  # A top-level YAML key can itself be a non-binary (flow-style complex key
  # like `[a, b]:`). Regex.escape/1 only accepts binaries, so guard first to
  # keep parse/1 total: report the inspected key, no source line.
  defp degraded_entry(key, _block) when not is_binary(key) do
    %{key: inspect(key), line: nil, snippet: truncate_snippet(inspect(key))}
  end

  defp degraded_entry(key, block) do
    lines = String.split(block, "\n")
    idx = Enum.find_index(lines, fn l -> Regex.match?(~r/^#{Regex.escape(key)}\s*:/, l) end)
    line = if idx, do: idx + 1, else: nil
    %{key: key, line: line, snippet: truncate_snippet(key <> ":")}
  end

  # Bound the redacted `snippet` (a key name) so a pathologically long key
  # can't balloon the plaintext `parse_reason` jsonb column or the /sync/changes
  # feed payload. Never carries a frontmatter value (see degraded_entry/2).
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
  @spec emit([String.t()], %{String.t() => term()}, %{String.t() => String.t()}) :: String.t()
  def emit(order, values, raws \\ %{})

  def emit([], _values, _raws), do: ""

  def emit(order, values, raws)
      when is_list(order) and is_map(values) and is_map(raws) do
    order
    |> Enum.filter(fn k -> Map.has_key?(raws, k) or Map.has_key?(values, k) end)
    |> Enum.map_join("", fn key ->
      case Map.fetch(raws, key) do
        # A degraded key is re-rendered from its verbatim out-of-band source
        # span (never via Ymlr, which would canonicalize/lose it).
        {:ok, raw} -> ensure_trailing_newline(raw)
        :error -> emit_key(key, values[key])
      end
    end)
    |> ensure_trailing_newline()
  end

  # A good key is decoded then emitted as canonical YAML. Raw passthrough is
  # handled out of band in emit/3 (the `raws` map), so a normal value here is
  # NEVER mistaken for a marker: this path only ever sees real values.
  defp emit_key(key, value) do
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

  @doc """
  Assemble full note plaintext from frontmatter parts and body. `raws` (the
  out-of-band degraded-key source spans) defaults to empty for good-only docs.
  """
  @spec project([String.t()], %{String.t() => String.t()}, String.t(), %{
          String.t() => String.t()
        }) :: String.t()
  def project(order, values, body, raws \\ %{})

  def project([], _values, body, _raws), do: body

  def project(order, values, body, raws) when is_binary(body) do
    case emit(order, values, raws) do
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
