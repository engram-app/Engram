defmodule Engram.Notes.CrdtBridge do
  @moduledoc """
  Pure CRDT diff-bridge between engram's plaintext write path and a Yjs doc.

  Posture C, file-level: REST/MCP/channel writers send whole-document
  plaintext; this module applies it onto the canonical `Y.Text` as a minimal
  contiguous-span edit (common-prefix + common-suffix preserved), then encodes
  the v1 state. NEVER deletes-all-and-reinserts (that destroys CRDT history and
  defeats convergent merge). No DB and no crypto here — callers own those.

  All docs are created with `offset_kind: :utf16` so `Yex.Text.insert/delete`
  indices are UTF-16 code units — wire-compatible with Yjs JS clients
  (spec §12a contract 4). NEVER use the `y_ex` default (`:bytes`).
  """

  import Bitwise

  alias Engram.Notes.Frontmatter

  @text_name "content"
  @frontmatter_name "frontmatter"
  @order_name "frontmatter_order"
  @doc_schema_version 2
  @flatten_bytes 500_000
  @flatten_clients 1_000

  @doc "The shared Y.Text key holding note body content."
  @spec text_name() :: String.t()
  def text_name, do: @text_name

  @doc "The CRDT doc schema version. Bump on any incompatible doc-shape change."
  @spec doc_schema_version() :: pos_integer()
  def doc_schema_version, do: @doc_schema_version

  @doc """
  Current frontmatter order list and JSON-encoded values map of a doc.

  Returns `{[], %{}}` for a fresh doc where neither the `@order_name` Y.Array
  nor the `@frontmatter_name` Y.Map have ever been written to.
  """
  @spec frontmatter_of(Yex.Doc.t()) :: {[String.t()], %{String.t() => String.t()}}
  def frontmatter_of(%Yex.Doc{} = doc) do
    order = doc |> Yex.Doc.get_array(@order_name) |> Yex.Array.to_list()
    values = doc |> Yex.Doc.get_map(@frontmatter_name) |> Yex.Map.to_map()
    {order, values}
  end

  @doc """
  A fresh Y.Doc with the UTF-16 offset kind. The SINGLE source of truth for
  doc creation in the backend CRDT path — `SharedDoc` (Task 6) passes the same
  `offset_kind: :utf16` via its `:doc_option` launch param, so every doc that
  ever holds note content agrees on the offset unit with JS clients.
  """
  @spec new_doc() :: Yex.Doc.t()
  def new_doc do
    # client_id 0 in Options is taken literally by the NIF (no auto-assign).
    # Each doc must have a unique ID so CRDT conflict-resolution can distinguish
    # concurrent edits when two divergent docs are merged via apply_update.
    client_id = :rand.uniform(0xFFFF_FFFF)

    Yex.Doc.with_options(%Yex.Doc.Options{
      client_id: client_id,
      offset_kind: :utf16,
      # The Rust NIF success typing infers collection_id: binary() (not nil).
      # Pass "" so the struct literal matches the NIF's inferred argument type
      # and dialyzer doesn't cascade no_return through doc_from_state/flatten.
      collection_id: ""
    })
  end

  @doc "A fresh Y.Doc, with `state` (a v1 update binary) applied when present."
  @spec doc_from_state(binary() | nil) :: {:ok, Yex.Doc.t()} | {:error, term()}
  def doc_from_state(nil), do: {:ok, new_doc()}

  def doc_from_state(state) when is_binary(state) do
    doc = new_doc()

    case Yex.apply_update(doc, state) do
      :ok -> {:ok, doc}
      {:error, reason} -> {:error, {:apply_update_failed, reason}}
    end
  end

  @doc "Rebuild full note plaintext from the doc's frontmatter + body."
  @spec project_doc(Yex.Doc.t()) :: String.t()
  def project_doc(%Yex.Doc{} = doc) do
    {order, values} = frontmatter_of(doc)
    Frontmatter.project(order, values, body_of(doc))
  end

  @doc "Full projected note plaintext (frontmatter + body)."
  @spec text_of(Yex.Doc.t()) :: String.t()
  def text_of(%Yex.Doc{} = doc), do: project_doc(doc)

  @doc "Body-only plaintext (the content Y.Text, no frontmatter)."
  @spec body_of(Yex.Doc.t()) :: String.t()
  def body_of(%Yex.Doc{} = doc) do
    doc |> Yex.Doc.get_text(@text_name) |> Yex.Text.to_string()
  end

  @doc """
  Load `state` into a fresh doc, converge its content to `incoming` via a
  minimal edit, and return the re-encoded v1 state plus the resulting text.
  """
  @spec merge_plaintext(binary() | nil, String.t()) ::
          {:ok, %{state: binary(), text: String.t()}} | {:error, term()}
  def merge_plaintext(state, incoming) when is_binary(incoming) do
    with {:ok, doc} <- doc_from_state(state),
         :ok <- ingest_plaintext(doc, incoming),
         {:ok, encoded} <- Yex.encode_state_as_update(doc) do
      {:ok, %{state: encoded, text: project_doc(doc)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Apply `incoming` onto `text` as a single minimal insert/delete around the
  longest common prefix + suffix. No-op when already equal.

  Offsets are **UTF-16 code units** (the doc is `offset_kind: :utf16`), so an
  astral codepoint (emoji, U+10000+) contributes 2 to every index and the diff
  never slices through a surrogate pair. The diff is computed over codepoint
  lists for correctness, then each span's length is converted to UTF-16 units
  before calling `Yex.Text.insert/delete`.
  """
  @spec diff_into_text(Yex.Text.t(), String.t()) :: :ok
  def diff_into_text(%Yex.Text{} = text, incoming) when is_binary(incoming) do
    current = Yex.Text.to_string(text)

    if current == incoming do
      :ok
    else
      cur = String.codepoints(current)
      inc = String.codepoints(incoming)

      prefix = common_prefix_len(cur, inc, 0)

      cur_rest = Enum.drop(cur, prefix)
      inc_rest = Enum.drop(inc, prefix)

      suffix =
        common_prefix_len(Enum.reverse(cur_rest), Enum.reverse(inc_rest), 0)
        |> min(length(cur_rest))
        |> min(length(inc_rest))

      deleted_cps = Enum.take(cur_rest, length(cur_rest) - suffix)
      inserted_cps = Enum.take(inc_rest, length(inc_rest) - suffix)

      # Convert codepoint spans to UTF-16 code-unit offsets/lengths.
      prefix_u16 = utf16_units(Enum.take(cur, prefix))
      delete_u16 = utf16_units(deleted_cps)
      insert_str = Enum.join(inserted_cps)

      if delete_u16 > 0, do: Yex.Text.delete(text, prefix_u16, delete_u16)
      if insert_str != "", do: Yex.Text.insert(text, prefix_u16, insert_str)
      :ok
    end
  end

  @doc """
  Ingest full note plaintext into the doc's frontmatter Y.Map + order Y.Array and
  body Y.Text. Only changed map keys are written. Malformed frontmatter falls
  back to treating the entire text as body.
  """
  @spec ingest_plaintext(Yex.Doc.t(), String.t()) :: :ok
  def ingest_plaintext(%Yex.Doc{} = doc, plaintext) when is_binary(plaintext) do
    {fm_block, body} = Frontmatter.split(plaintext)

    {order, values, body} =
      case fm_block && Frontmatter.parse(fm_block) do
        {:ok, order, values} -> {order, values, body}
        # nil (no frontmatter) or :error (malformed) -> whole text is body
        _ -> {[], %{}, plaintext}
      end

    apply_frontmatter(doc, order, values)
    text = Yex.Doc.get_text(doc, @text_name)
    :ok = diff_into_text(text, body)
    :ok
  end

  defp apply_frontmatter(doc, order, values) do
    map = Yex.Doc.get_map(doc, @frontmatter_name)
    current = Yex.Map.to_map(map)

    # Upsert changed keys.
    Enum.each(values, fn {k, v} ->
      if Map.get(current, k) != v, do: Yex.Map.set(map, k, v)
    end)

    # Delete keys no longer present.
    Enum.each(Map.keys(current), fn k ->
      unless Map.has_key?(values, k), do: Yex.Map.delete(map, k)
    end)

    # Replace the order array wholesale (small list; simplest correct form).
    arr = Yex.Doc.get_array(doc, @order_name)
    len = arr |> Yex.Array.to_list() |> length()
    if len > 0, do: Yex.Array.delete_range(arr, 0, len)
    if order != [], do: Yex.Array.insert_list(arr, 0, order)
    :ok
  end

  @doc """
  Distinct client IDs present in the doc's state vector.

  The y-js v1 state vector is LEB128-encoded: a leading varint gives the
  number of entries, followed by alternating `{client_id}{clock}` varints.
  We decode only the leading count — O(1) and allocation-free.
  """
  @spec client_count(Yex.Doc.t()) :: non_neg_integer()
  def client_count(%Yex.Doc{} = doc) do
    {count, _rest} = read_varint(Yex.encode_state_vector!(doc))
    count
  end

  @doc """
  True only when BOTH the encoded-state byte ceiling AND the client-ID
  ceiling are crossed. A large note with few authors must NOT flatten;
  a small note with many stale client-IDs must NOT flatten. AND is required.
  """
  @spec should_flatten?(binary(), Yex.Doc.t()) :: boolean()
  def should_flatten?(state, %Yex.Doc{} = doc) when is_binary(state) do
    byte_size(state) >= @flatten_bytes and client_count(doc) >= @flatten_clients
  end

  @doc """
  Text-preserving CRDT reset. Extracts the current content, seeds a fresh
  single-client doc, and re-encodes — collapsing all accumulated client-ID
  entries in the state vector to one. Lineage is intentionally broken; this
  is a deliberate reset, not a merge.
  """
  @spec flatten(Yex.Doc.t()) :: {:ok, %{doc: Yex.Doc.t(), state: binary()}} | {:error, term()}
  def flatten(%Yex.Doc{} = doc) do
    fresh = new_doc()
    :ok = ingest_plaintext(fresh, project_doc(doc))

    case Yex.encode_state_as_update(fresh) do
      {:ok, state} -> {:ok, %{doc: fresh, state: state}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp common_prefix_len([h | t1], [h | t2], acc), do: common_prefix_len(t1, t2, acc + 1)
  defp common_prefix_len(_, _, acc), do: acc

  # UTF-16 code-unit count for a list of codepoints (BMP = 1, astral = 2).
  defp utf16_units(codepoints) do
    Enum.reduce(codepoints, 0, fn cp, acc ->
      <<code::utf8>> = cp
      acc + if code >= 0x10000, do: 2, else: 1
    end)
  end

  # Minimal LEB128 unsigned varint reader (lib0 v1 codec used by y-js).
  # A single-byte varint has its MSB clear; multi-byte continues until MSB clear.
  defp read_varint(<<byte, rest::binary>>) when (byte &&& 0x80) == 0, do: {byte, rest}

  defp read_varint(<<byte, rest::binary>>) do
    {next, tail} = read_varint(rest)
    {(byte &&& 0x7F) ||| next <<< 7, tail}
  end
end
