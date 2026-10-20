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
    fm_attrs: "at",
    fm_nums: "nm",
    fm_dates: "dt",
    fm_timestamp_src: "us",
    fm_created_src: "cs"
  ]

  @short Map.new(@keys)
  @long Map.new(@keys, fn {l, s} -> {s, l} end)

  # ponytail: in memory, not `on_disk` as spec 3.3b asks. The first CI run with
  # on-disk payload indexes SIGBUSed Qdrant 1.19.2 on its 2 GB tmpfs (each
  # mutable on-disk index preallocates its storage), and a field no point
  # carries costs ~0 heap. Switch to on_disk once its per-index disk footprint
  # is measured on dev 1.19.2, BEFORE prod's disk sees 20 of them per segment.
  @range %{"type" => "integer", "lookup" => false, "range" => true}
  @uuid %{"type" => "uuid"}
  @float %{"type" => "float"}

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
  The v5 payload indexes as `{field, schema}` (in memory for now, see the
  schema attributes). `u` also gets `is_tenant` on Qdrant >= 1.19.2 (Task 8.1, layout).
  The source flags are payload only.
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
        {short(:fm_attrs) <> "[].k", @uuid},
        {short(:fm_attrs) <> "[].v", @uuid},
        {short(:fm_nums) <> "[].k", @uuid},
        {short(:fm_nums) <> "[].n", @float},
        {short(:fm_dates) <> "[].k", @uuid},
        {short(:fm_dates) <> "[].t", @range}
      ]
  end
end
