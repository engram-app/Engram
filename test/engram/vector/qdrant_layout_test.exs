defmodule Engram.Vector.QdrantLayoutTest do
  use ExUnit.Case, async: true

  alias Engram.Vector.QdrantLayout

  # GET /collections/engram_notes on prod (Qdrant Cloud 1.18.2), 2026-10-18.
  @prod_info "test/support/fixtures/qdrant/collection_info_prod_2026_10_18.json"
             |> File.read!()
             |> Jason.decode!()

  @v1182 Version.parse!("1.18.2")
  @v1181 Version.parse!("1.18.1")
  @v1171 Version.parse!("1.17.1")

  # What `config` reads back once the desired params are applied: Qdrant
  # echoes the merged values under its GET field names (`optimizer_config`,
  # `params.vectors`, `params.sparse_vectors`).
  defp applied(info) do
    info
    |> put_in(["config", "params", "vectors", "dense", "on_disk"], true)
    |> put_in(["config", "params", "sparse_vectors", "keyword", "index"], %{"on_disk" => true})
    |> put_in(["config", "optimizer_config", "max_optimization_threads"], 1)
    |> put_in(["config", "strict_mode_config"], %{
      "enabled" => true,
      "unindexed_filtering_retrieve" => false,
      "max_disk_usage_percent" => 85,
      "max_resident_memory_percent" => 85
    })
  end

  describe "desired/1" do
    test "PATCH body shape per sub-object on 1.18.2" do
      assert QdrantLayout.desired(@v1182) == %{
               "vectors" => %{"dense" => %{"on_disk" => true}},
               "sparse_vectors" => %{
                 "keyword" => %{"modifier" => "idf", "index" => %{"on_disk" => true}}
               },
               "optimizers_config" => %{"max_optimization_threads" => 1},
               "strict_mode_config" => %{
                 "enabled" => true,
                 "max_disk_usage_percent" => 85,
                 "max_resident_memory_percent" => 85
               }
             }
    end

    test "1.18.1 has the memory guard but not the disk guard" do
      assert QdrantLayout.desired(@v1181)["strict_mode_config"] == %{
               "enabled" => true,
               "max_resident_memory_percent" => 85
             }
    end

    test "strict mode is omitted entirely on 1.17.1 (self-host pin) and unknown versions" do
      refute Map.has_key?(QdrantLayout.desired(@v1171), "strict_mode_config")
      refute Map.has_key?(QdrantLayout.desired(nil), "strict_mode_config")
    end

    test "never changes size, distance or datatype" do
      dense = QdrantLayout.desired(@v1182)["vectors"]["dense"]
      refute Map.has_key?(dense, "size")
      refute Map.has_key?(dense, "distance")
      refute Map.has_key?(dense, "datatype")
    end
  end

  describe "diff/2" do
    test "is a no-op on an already-applied config" do
      assert QdrantLayout.diff(applied(@prod_info)["config"], QdrantLayout.desired(@v1182)) ==
               %{}
    end

    test "today's prod shape changes exactly the three storage sub-objects (no strict support)" do
      diff = QdrantLayout.diff(@prod_info["config"], QdrantLayout.desired(@v1171))

      assert diff == %{
               "vectors" => %{"dense" => %{"on_disk" => true}},
               "sparse_vectors" => %{
                 "keyword" => %{"modifier" => "idf", "index" => %{"on_disk" => true}}
               },
               "optimizers_config" => %{"max_optimization_threads" => 1}
             }
    end

    test "today's prod shape on 1.18.2 adds the strict-mode guards" do
      diff = QdrantLayout.diff(@prod_info["config"], QdrantLayout.desired(@v1182))

      assert Map.keys(diff) |> Enum.sort() ==
               ~w(optimizers_config sparse_vectors strict_mode_config vectors)
    end

    test "only the drifted sub-object comes back" do
      config =
        applied(@prod_info)
        |> put_in(["config", "optimizer_config", "max_optimization_threads"], nil)
        |> Map.fetch!("config")

      assert QdrantLayout.diff(config, QdrantLayout.desired(@v1182)) == %{
               "optimizers_config" => %{"max_optimization_threads" => 1}
             }
    end

    test "a missing strict_mode_config counts as drift" do
      config = applied(@prod_info)["config"] |> Map.delete("strict_mode_config")

      assert Map.keys(QdrantLayout.diff(config, QdrantLayout.desired(@v1182))) ==
               ["strict_mode_config"]
    end
  end

  describe "create_params/1" do
    test "a fresh collection is created with the storage params directly" do
      body = QdrantLayout.create_params(1024)

      assert body["vectors"]["dense"] == %{
               "size" => 1024,
               "distance" => "Cosine",
               "on_disk" => true
             }

      assert body["sparse_vectors"]["keyword"] == %{
               "modifier" => "idf",
               "index" => %{"on_disk" => true}
             }

      assert body["optimizers_config"] == %{"max_optimization_threads" => 1}
    end
  end

  describe "strict_limits/2" do
    @gib 1024 * 1024 * 1024
    @mib 1024 * 1024
    @opts %{memory_reserve: 256 * @mib, static: %{disk: 85, heap: 85}}

    test "today's prod: disk reserve 0.35x collection -> 79%, memory 2 GiB - 256 MiB -> 87%" do
      limits =
        QdrantLayout.strict_limits(
          %{capacity: 8_370_000_000, collection: 4_890_000_000, memory_limit: 2 * @gib},
          @opts
        )

      assert limits == %{
               disk: %{percent: 79, reserve: 1_711_500_000},
               heap: %{percent: 87, reserve: 256 * @mib}
             }
    end

    test "the same data on a 16 GiB volume -> 90%" do
      assert %{disk: %{percent: 90}} =
               QdrantLayout.strict_limits(
                 %{capacity: 16 * @gib, collection: 4_890_000_000, memory_limit: nil},
                 @opts
               )
    end

    test "disk reserve is at least 1 GiB" do
      assert %{disk: %{percent: 87, reserve: 1_073_741_824}} =
               QdrantLayout.strict_limits(
                 %{capacity: 8_370_000_000, collection: 1_000_000_000, memory_limit: nil},
                 @opts
               )
    end

    test "clamped to 70..95" do
      small = %{capacity: 2_000_000_000, collection: 1_000_000_000, memory_limit: 300 * @mib}

      assert %{disk: %{percent: 70}, heap: %{percent: 70}} =
               QdrantLayout.strict_limits(small, @opts)

      big = %{capacity: 1_000_000_000_000, collection: 1_000, memory_limit: 64 * @gib}

      assert %{disk: %{percent: 95}, heap: %{percent: 95}} =
               QdrantLayout.strict_limits(big, @opts)
    end

    test "memory reserve is the configured value, never below 256 MiB" do
      vol = %{capacity: nil, collection: nil, memory_limit: 2 * @gib}

      assert %{heap: %{percent: 75, reserve: 536_870_912}} =
               QdrantLayout.strict_limits(vol, %{@opts | memory_reserve: 512 * @mib})

      assert %{heap: %{percent: 87, reserve: 268_435_456}} =
               QdrantLayout.strict_limits(vol, %{@opts | memory_reserve: 100 * @mib})
    end

    test "unknown sizes keep the configured static percent" do
      unknown = %{capacity: nil, collection: 4_890_000_000, memory_limit: nil}

      assert QdrantLayout.strict_limits(unknown, %{@opts | static: %{disk: 83, heap: 81}}) == %{
               disk: %{percent: 83, reserve: nil},
               heap: %{percent: 81, reserve: nil}
             }

      assert %{disk: %{percent: 85, reserve: nil}} =
               QdrantLayout.strict_limits(
                 %{unknown | capacity: 8_370_000_000, collection: nil},
                 @opts
               )
    end

    test "desired/2 takes the limits' percents" do
      limits = %{disk: %{percent: 79, reserve: 1}, heap: %{percent: 87, reserve: 1}}

      assert QdrantLayout.desired(Version.parse!("1.18.2"), limits)["strict_mode_config"] == %{
               "enabled" => true,
               "max_disk_usage_percent" => 79,
               "max_resident_memory_percent" => 87
             }
    end
  end
end
