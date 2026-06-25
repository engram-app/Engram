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

  @text_name "content"

  @doc "The shared Y.Text key holding note body content."
  @spec text_name() :: String.t()
  def text_name, do: @text_name

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
    Yex.Doc.with_options(%Yex.Doc.Options{client_id: client_id, offset_kind: :utf16})
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

  @doc "Current plaintext of the doc's content Y.Text."
  @spec text_of(Yex.Doc.t()) :: String.t()
  def text_of(%Yex.Doc{} = doc) do
    doc |> Yex.Doc.get_text(@text_name) |> Yex.Text.to_string()
  end

  @doc """
  Load `state` into a fresh doc, converge its content to `incoming` via a
  minimal edit, and return the re-encoded v1 state plus the resulting text.
  """
  @spec merge_plaintext(binary() | nil, String.t()) ::
          {:ok, %{state: binary(), text: String.t()}} | {:error, term()}
  def merge_plaintext(state, incoming) when is_binary(incoming) do
    with {:ok, doc} <- doc_from_state(state) do
      text = Yex.Doc.get_text(doc, @text_name)
      :ok = diff_into_text(text, incoming)

      case Yex.encode_state_as_update(doc) do
        {:ok, encoded} -> {:ok, %{state: encoded, text: Yex.Text.to_string(text)}}
        {:error, reason} -> {:error, {:encode_failed, reason}}
      end
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

  defp common_prefix_len([h | t1], [h | t2], acc), do: common_prefix_len(t1, t2, acc + 1)
  defp common_prefix_len(_, _, acc), do: acc

  # UTF-16 code-unit count for a list of codepoints (BMP = 1, astral = 2).
  defp utf16_units(codepoints) do
    Enum.reduce(codepoints, 0, fn cp, acc ->
      <<code::utf8>> = cp
      acc + if code >= 0x10000, do: 2, else: 1
    end)
  end
end
