defmodule Engram.Vector.PayloadKeys do
  @moduledoc """
  The one mapping from logical v5 payload names to the 1-2 character keys
  Qdrant stores and indexes (spec 3.3b, minimal payload). The v5 write path,
  every filter builder and the payload-index list go through `short/1`, so a
  long name can never reach a v5 point. `long/1` decodes for debugging.

  v3/v4 points keep their long `*_hmac` names; those are not in this map.
  """

  @keys [
    user_id: "u",
    vault_id: "v",
    path_id: "p",
    folder_id: "f",
    type_id: "y",
    tags_id: "g",
    status_id: "s",
    author_id: "a",
    rev_by_id: "r",
    src_id: "o",
    proj_id: "j",
    fm_timestamp: "up",
    fm_created: "cr",
    fm_reviewed: "rd",
    fm_expires: "ex",
    fm_due: "du",
    fm_priority: "pr",
    fm_attrs: "fa",
    fm_timestamp_src: "us",
    fm_created_src: "cs",
    # The point's note row id (immutable chunk index, Engram#2263): what a
    # filtered search matches once Postgres has resolved the filters to notes.
    note: "n"
  ]

  @short Map.new(@keys)
  @long Map.new(@keys, fn {l, s} -> {s, l} end)

  @uuid %{"type" => "uuid", "on_disk" => true}

  # #590: plaintext note metadata that points written before the fix carry.
  # The one list: `Qdrant.delete_leaked_plaintext_keys/1`.
  @leaked_plaintext ~w(source_path folder tags)

  @doc "Keys that leaked plaintext into pre-#590 payloads."
  @spec leaked_plaintext_keys() :: [String.t()]
  def leaked_plaintext_keys, do: @leaked_plaintext

  @doc "Logical names, in declaration order."
  @spec logical_names() :: [atom()]
  def logical_names, do: Keyword.keys(@keys)

  @doc "Short key for a logical name. Raises on an unknown name."
  @spec short(atom()) :: String.t()
  def short(name), do: Map.fetch!(@short, name)

  @doc "Logical name for a short key (debugging); nil when unknown."
  @spec long(String.t()) :: atom() | nil
  def long(short), do: Map.get(@long, short)

  @doc "Decode a v5 payload's keys to logical names, for logs and debugging."
  @spec decode(map()) :: map()
  def decode(payload), do: Map.new(payload, fn {k, v} -> {long(to_string(k)) || k, v} end)

  @doc """
  The v5 payload indexes as `{field, schema}`: the identity keys `u`, `v`,
  `n` (R3a: a point's whole payload) plus `p`, which the note belts
  (`Qdrant.note_filter/3`) still match points written before `n` by. All on
  disk. On Qdrant >= 1.19.2 `QdrantLayout.payload_indexes/2` adds `is_tenant`
  to `u` and `enable_hnsw: false` to the rest. The other v5 keys are no longer
  indexed on a new collection; an existing index is left alone.
  """
  @spec index_fields() :: [{String.t(), map()}]
  def index_fields, do: Enum.map(~w(user_id vault_id note path_id)a, &{short(&1), @uuid})
end
