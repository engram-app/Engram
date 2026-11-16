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
  `n` (R3a: a point's whole payload). All on disk. On Qdrant >= 1.19.2
  `QdrantLayout.payload_indexes/2` adds `is_tenant` to `u` and
  `enable_hnsw: false` to the rest.
  """
  @spec index_fields() :: [{String.t(), map()}]
  def index_fields, do: Enum.map(~w(user_id vault_id note)a, &{short(&1), @uuid})

  # The v5 keys indexed before R3a (`us`/`cs` never were), with the `fa`
  # sub-keys as indexed.
  @retired_v5 Enum.map(
                ~w(path_id folder_id type_id tags_id status_id author_id rev_by_id src_id
                   proj_id fm_timestamp fm_created fm_reviewed fm_expires fm_due fm_priority)a,
                &Keyword.fetch!(@keys, &1)
              ) ++ Enum.map(~w(k h n d), &"#{@keys[:fm_attrs]}[].#{&1}")

  # The legacy (v3/v4) indexes, but the tenant `user_id`/`vault_id` that
  # `Qdrant.match_filter/2` still reads while `:legacy_filter_fields` is on.
  @retired_legacy ~w(path_hmac type_hmac folder_hmac tags_hmac note_id fm_timestamp fm_created)

  @doc """
  Payload indexes an earlier release created and no reader filters on any
  more (R3b): every v5 key but `u`/`v`/`n` (the note belts match by `n`
  alone, every other filter resolves in Postgres) and the legacy path,
  folder, tag, type, date and `note_id` keys. `Qdrant.ensure_collection/2`
  drops the ones an existing collection still has; none is ever created.
  """
  @spec retired_index_fields() :: [String.t()]
  def retired_index_fields, do: @retired_v5 ++ @retired_legacy
end
