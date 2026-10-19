defmodule Engram.Vector.QdrantLayout do
  @moduledoc """
  Desired storage + safety params for the EXISTING Qdrant collection, and the
  diff against what `GET /collections/{name}` reports. Pure: no HTTP.

  Measured on prod 2026-10-18 (Qdrant Cloud 1.18.2, 447k points): the sparse
  `keyword` index (419 MB) and payload indexes (~140 MB) are the bulk of RAM;
  dense storage is already mmap'd. So this moves the sparse index and dense
  vectors on disk, serialises optimizer rebuilds onto one thread, and turns on
  strict-mode upsert guards for memory and disk.

  Deliberately NOT here: `datatype` (float16 needs a new collection) and
  `max_segment_size` / `default_segment_number` (need a disk-headroom gate).

  Field names are the PATCH (`UpdateCollection`) names. The GET response names
  two of them differently (`optimizers_config` reads back as
  `optimizer_config`, vectors live under `params`), which `diff/2` maps.
  Every PATCH sub-object is merged into the current config by Qdrant
  (`update_collection` in `toc/collection_meta_ops.rs`), not replaced, so a
  partial body never resets an unrelated setting.
  """

  # Strict-mode fields by the first Qdrant release that accepts them
  # (openapi.json per tag: resident memory 1.18.1, disk 1.18.2). Self-host CI
  # pins 1.17.1, which has neither.
  @strict_guards [
    {"max_resident_memory_percent", :heap, "1.18.1"},
    {"max_disk_usage_percent", :disk, "1.18.2"}
  ]

  @default_limits %{disk: %{percent: 85, reserve: nil}, heap: %{percent: 85, reserve: nil}}
  @off_limits %{disk: %{percent: 100, reserve: nil}, heap: %{percent: 100, reserve: nil}}

  @gib 1024 * 1024 * 1024
  @min_memory_reserve 256 * 1024 * 1024

  @storage %{
    "vectors" => %{"dense" => %{"on_disk" => true}},
    "sparse_vectors" => %{"keyword" => %{"modifier" => "idf", "index" => %{"on_disk" => true}}},
    "optimizers_config" => %{"max_optimization_threads" => 1}
  }

  # PATCH key -> path of the same settings in the GET `config` object.
  @get_path %{
    "vectors" => ["params", "vectors"],
    "sparse_vectors" => ["params", "sparse_vectors"],
    "optimizers_config" => ["optimizer_config"],
    "strict_mode_config" => ["strict_mode_config"]
  }

  @doc """
  The desired PATCH sub-objects for a server at `version` (`nil` = unknown),
  with strict mode refusing writes at `limits` (see `strict_limits/2`;
  default 85/85), or switched off when `strict?` is false.
  Strict mode is included only with at least one guard the server supports:
  enabling it with no guard adds risk for no protection.
  """
  @spec desired(Version.t() | nil, map() | nil, boolean()) :: map()
  def desired(version, limits \\ @default_limits, strict? \\ true)

  # Ops kill switch (QDRANT_STRICT_MODE=false): our two guards at 100 (a
  # refusal only on a full disk/heap), never `enabled: false`, which would also
  # drop Qdrant Cloud's own strict-mode guards (unindexed filtering). 100, not
  # null: the strict-mode PATCH merge keeps the old value for a null field
  # (`x.or(self.x)` in lib/collection/src/operations/config_diff.rs, 1.18.2).
  def desired(version, _limits, false) do
    case supported_guards(version, @off_limits) do
      [] -> @storage
      guards -> Map.put(@storage, "strict_mode_config", Map.new(guards))
    end
  end

  def desired(version, limits, true) do
    case supported_guards(version, limits || @default_limits) do
      [] -> @storage
      guards -> Map.put(@storage, "strict_mode_config", Map.new([{"enabled", true} | guards]))
    end
  end

  defp supported_guards(nil, _limits), do: []

  defp supported_guards(version, limits) do
    for {field, kind, since} <- @strict_guards,
        Version.compare(version, since) != :lt,
        do: {field, limits[kind].percent}
  end

  @doc """
  Strict-mode refusal limits, in whole percent, from an absolute reserve so
  they scale with the cluster instead of sitting at a fixed 85:

    * disk: reserve `max(1 GiB, 0.35 x collection disk_bytes)` of the
      volume's capacity (0.35 = the on-disk rewrite's measured 0.26x peak
      plus margin);
    * heap: reserve `max(256 MiB, opts.memory_reserve)` of the container
      memory limit (a rewrite's measured heap spike is ~0.25 GB).

  `floor(100 * (size - reserve) / size)`, clamped to 70..95. An unknown size
  keeps `opts.static`. Returns `%{disk: %{percent:, reserve:}, heap: ...}`
  (`reserve` nil when static).
  """
  @spec strict_limits(map(), map()) :: map()
  def strict_limits(%{capacity: cap, collection: coll, memory_limit: mem}, opts) do
    # ponytail: 0.35x is the whole-collection rewrite budget; switch the disk
    # reserve to 2 x max_segment_size once segments are capped.
    disk_reserve = if is_integer(coll), do: max(@gib, div(coll * 35, 100))
    heap_reserve = max(@min_memory_reserve, opts.memory_reserve)

    %{
      disk: limit(cap, disk_reserve, opts.static.disk),
      heap: limit(mem, heap_reserve, opts.static.heap)
    }
  end

  defp limit(size, reserve, _static) when is_integer(size) and size > 0 and is_integer(reserve),
    do: %{percent: (100 * (size - reserve)) |> div(size) |> max(70) |> min(95), reserve: reserve}

  defp limit(_size, _reserve, static), do: %{percent: static, reserve: nil}

  @doc "PATCH keys that move data on disk (headroom-gated by the caller)."
  @spec on_disk_keys() :: [String.t()]
  def on_disk_keys, do: ["vectors", "sparse_vectors"]

  @doc "Create-collection body: the desired storage params plus shape."
  @spec create_params(pos_integer()) :: map()
  def create_params(dims) do
    put_in(@storage, ["vectors", "dense"], %{
      "size" => dims,
      "distance" => "Cosine",
      "on_disk" => true
    })
  end

  @doc """
  The desired sub-objects `config` (the GET `result.config`) does not already
  satisfy. `%{}` when everything is applied, so a boot costs no PATCH.
  """
  @spec diff(map(), map()) :: map()
  def diff(config, desired) do
    desired
    |> Enum.reject(fn {key, want} -> subset?(want, get_in(config, @get_path[key])) end)
    |> Map.new()
  end

  defp subset?(want, have) when is_map(want) and is_map(have),
    do: Enum.all?(want, fn {k, v} -> subset?(v, Map.get(have, k)) end)

  defp subset?(want, have), do: want == have
end
