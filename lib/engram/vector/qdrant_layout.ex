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
    {"max_resident_memory_percent", :memory, "1.18.1"},
    {"max_disk_usage_percent", :disk, "1.18.2"}
  ]

  @default_thresholds %{disk: 85, memory: 85}

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
  with strict mode refusing writes at `thresholds` percent (default 85/85).
  Strict mode is included only with at least one guard the server supports:
  enabling it with no guard adds risk for no protection.
  """
  @spec desired(Version.t() | nil, %{disk: 1..100, memory: 1..100}) :: map()
  def desired(version, thresholds \\ @default_thresholds) do
    case supported_guards(version, thresholds) do
      [] -> @storage
      guards -> Map.put(@storage, "strict_mode_config", Map.new([{"enabled", true} | guards]))
    end
  end

  defp supported_guards(nil, _thresholds), do: []

  defp supported_guards(version, thresholds) do
    for {field, kind, since} <- @strict_guards,
        Version.compare(version, since) != :lt,
        do: {field, Map.fetch!(thresholds, kind)}
  end

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
