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
    fm_created_src: "cs"
  ]

  @short Map.new(@keys)
  @long Map.new(@keys, fn {l, s} -> {s, l} end)

  @range %{"type" => "integer", "lookup" => false, "range" => true, "on_disk" => true}
  @uuid %{"type" => "uuid", "on_disk" => true}
  @float %{"type" => "float", "on_disk" => true}
  @keyword %{"type" => "keyword", "on_disk" => true}
  @key_id %{"type" => "integer", "lookup" => true, "range" => false, "on_disk" => true}

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
  The v5 payload indexes as `{field, schema}`. All on disk, so the heap cost is
  near zero. On
  Qdrant >= 1.19.2 `QdrantLayout.payload_indexes/2` adds `is_tenant` to `u`
  and `enable_hnsw: false` to the rest (Task 8.1). The source flags are
  payload only.
  """
  @spec index_fields() :: [{String.t(), map()}]
  def index_fields do
    uuid = ~w(user_id vault_id path_id folder_id type_id tags_id status_id author_id
              rev_by_id src_id proj_id)a

    range = ~w(fm_timestamp fm_created fm_reviewed fm_expires fm_due)a

    Enum.map(uuid, &{short(&1), @uuid}) ++
      Enum.map(range, &{short(&1), @range}) ++
      [
        {short(:fm_priority), @float},
        # User-added keys, one nested entry per value: `k` the per-user key
        # id (`FrontmatterKeys`, exact lookups only), and one of `h` (an
        # exact value's filter id), `n` (number) or `d` (unix seconds).
        {short(:fm_attrs) <> "[].k", @key_id},
        {short(:fm_attrs) <> "[].h", @keyword},
        {short(:fm_attrs) <> "[].n", @float},
        {short(:fm_attrs) <> "[].d", @range}
      ]
  end
end
