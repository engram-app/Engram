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
  @v1192 Version.parse!("1.19.2")
  @v1210 Version.parse!("1.21.0")

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

  describe "applied_limits/2" do
    test "reads the limits Qdrant enforces, only for guards the version honours" do
      strict = %{
        "enabled" => true,
        "max_disk_usage_percent" => 81,
        "max_resident_memory_percent" => 83
      }

      config = %{"strict_mode_config" => strict}

      assert QdrantLayout.applied_limits(config, @v1182) == %{disk: 81, heap: 83}
      # 1.19 keeps a stored disk field from an older server but ignores it.
      assert QdrantLayout.applied_limits(config, @v1192) == %{heap: 83}
      assert QdrantLayout.applied_limits(config, nil) == %{}
    end

    test "nothing when strict mode is off or a field is unset" do
      off = %{"strict_mode_config" => %{"enabled" => false, "max_disk_usage_percent" => 81}}
      assert QdrantLayout.applied_limits(off, @v1182) == %{}
      assert QdrantLayout.applied_limits(@prod_info["config"], @v1182) == %{}
      assert QdrantLayout.applied_limits(nil, @v1182) == %{}
    end
  end

  describe "quotas (Qdrant 1.19+ node-wide guards)" do
    @limits %{disk: %{percent: 79, reserve: 1}, heap: %{percent: 87, reserve: 1}}

    test "quota_kinds: both guards from 1.19.0, none before or when unknown" do
      assert QdrantLayout.quota_kinds(@v1192) == [:disk, :heap]
      assert QdrantLayout.quota_kinds(Version.parse!("1.19.0")) == [:disk, :heap]
      assert QdrantLayout.quota_kinds(@v1210) == [:disk, :heap]
      assert QdrantLayout.quota_kinds(Version.parse!("1.18.3")) == []
      assert QdrantLayout.quota_kinds(@v1171) == []
      assert QdrantLayout.quota_kinds(nil) == []
    end

    test "desired_quotas: the full PUT body (PUT replaces), 100/100 when strict is off" do
      assert QdrantLayout.desired_quotas(@limits, true) == %{
               "enabled" => true,
               "max_disk_usage_percent" => 79,
               "max_resident_memory_percent" => 87
             }

      assert QdrantLayout.desired_quotas(nil, true) == %{
               "enabled" => true,
               "max_disk_usage_percent" => 85,
               "max_resident_memory_percent" => 85
             }

      assert QdrantLayout.desired_quotas(@limits, false) == %{
               "enabled" => true,
               "max_disk_usage_percent" => 100,
               "max_resident_memory_percent" => 100
             }
    end

    test "quotas_drift?: applied is no drift; a server default margin is not drift" do
      want = QdrantLayout.desired_quotas(@limits, true)
      refute QdrantLayout.quotas_drift?(Map.put(want, "release_margin_percent", nil), want)
      assert QdrantLayout.quotas_drift?(%{"enabled" => false}, want)
      assert QdrantLayout.quotas_drift?(%{want | "max_disk_usage_percent" => 80}, want)
      assert QdrantLayout.quotas_drift?(nil, want)
    end

    test "applied_limits/3 reports quota limits on 1.19, the stricter one when both apply" do
      strict = %{
        "strict_mode_config" => %{"enabled" => true, "max_resident_memory_percent" => 83}
      }

      quotas = %{
        "enabled" => true,
        "max_disk_usage_percent" => 79,
        "max_resident_memory_percent" => 87
      }

      assert QdrantLayout.applied_limits(strict, @v1192, quotas) == %{disk: 79, heap: 83}
      assert QdrantLayout.applied_limits(%{}, @v1192, quotas) == %{disk: 79, heap: 87}
      # Disabled quotas enforce nothing; a pre-1.19 server has no quotas.
      assert QdrantLayout.applied_limits(%{}, @v1192, %{quotas | "enabled" => false}) == %{}
      assert QdrantLayout.applied_limits(%{}, @v1182, quotas) == %{}
      assert QdrantLayout.applied_limits(strict, @v1192, nil) == %{heap: 83}
    end
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

    test "strict mode is omitted entirely on 1.17.1 (CI pin) and unknown versions" do
      refute Map.has_key?(QdrantLayout.desired(@v1171), "strict_mode_config")
      refute Map.has_key?(QdrantLayout.desired(nil), "strict_mode_config")
    end

    # Off = our two guards at 100 (Qdrant's strict-mode PATCH merge keeps the
    # old value for a null field: config_diff.rs `x.or(self.x)`, so null
    # cannot clear one). `enabled` and every other strict field are left as
    # they are, so Qdrant Cloud's unindexed-filter guard survives.
    test "strict mode off: only our guards, at 100, version-gated" do
      assert QdrantLayout.desired(@v1182, nil, false)["strict_mode_config"] == %{
               "max_disk_usage_percent" => 100,
               "max_resident_memory_percent" => 100
             }

      assert QdrantLayout.desired(@v1181, nil, false)["strict_mode_config"] == %{
               "max_resident_memory_percent" => 100
             }

      refute Map.has_key?(QdrantLayout.desired(@v1171, nil, false), "strict_mode_config")
      refute Map.has_key?(QdrantLayout.desired(nil, nil, false), "strict_mode_config")
    end

    # Qdrant 1.19 moved max_disk_usage_percent to the node-wide /quotas
    # (absent from 1.19.0's StrictModeConfig); max_resident_memory_percent is
    # deprecated there, "Scheduled for removal in 1.21".
    test "the disk guard is 1.18.2 <= v < 1.19.0; memory 1.18.1 <= v < 1.21.0" do
      assert QdrantLayout.desired(@v1192)["strict_mode_config"] == %{
               "enabled" => true,
               "max_resident_memory_percent" => 85
             }

      refute Map.has_key?(QdrantLayout.desired(@v1210), "strict_mode_config")
      refute Map.has_key?(QdrantLayout.desired(@v1210, nil, false), "strict_mode_config")

      assert QdrantLayout.guard_kinds(@v1182) == [:heap, :disk]
      assert QdrantLayout.guard_kinds(Version.parse!("1.18.3")) == [:heap, :disk]
      assert QdrantLayout.guard_kinds(@v1192) == [:heap]
      assert QdrantLayout.guard_kinds(@v1210) == []
      assert QdrantLayout.guard_kinds(nil) == []
    end

    test "1.19.2: a strict config without the disk field is already applied" do
      config =
        @prod_info["config"]
        |> put_in(["params", "vectors", "dense", "on_disk"], true)
        |> put_in(["params", "sparse_vectors", "keyword", "index"], %{"on_disk" => true})
        |> put_in(["optimizer_config", "max_optimization_threads"], 1)
        |> put_in(["strict_mode_config"], %{
          "enabled" => true,
          "max_resident_memory_percent" => 85
        })

      assert QdrantLayout.diff(config, QdrantLayout.desired(@v1192)) == %{}
    end

    test "an existing float32 collection is not drift" do
      config =
        @prod_info["config"]
        |> put_in(["params", "vectors", "dense", "on_disk"], true)
        |> put_in(["params", "vectors", "dense", "datatype"], "float32")
        |> put_in(["params", "sparse_vectors", "keyword", "index"], %{"on_disk" => true})
        |> put_in(["optimizer_config", "max_optimization_threads"], 1)
        |> put_in(["strict_mode_config"], %{
          "enabled" => true,
          "max_resident_memory_percent" => 85
        })

      assert QdrantLayout.diff(config, QdrantLayout.desired(@v1192)) == %{}
    end

    test "never changes size, distance or datatype" do
      dense = QdrantLayout.desired(@v1182)["vectors"]["dense"]
      refute Map.has_key?(dense, "size")
      refute Map.has_key?(dense, "distance")
      refute Map.has_key?(dense, "datatype")
    end
  end

  describe "desired_strict/1 (hard limits, Qdrant Cloud only)" do
    # Circuit breakers against code bugs and runaway sweeps, from the
    # 10-19 config audit (#7) and docs sweep (#15). `search_allow_exact`
    # stays allowed (sweep #19): the ANN-recall check compares against
    # `params.exact: true`; max_query_limit and max_timeout bound it.
    # No read/write_rate_limit: they are per replica, not per tenant.
    # No byte breakers: a static byte number drifts with the layout, and the
    # disk and memory guards already refuse on live usage.
    test "cloud: exactly the audited limits, no byte breakers" do
      assert QdrantLayout.desired_strict(:cloud) == %{
               "max_query_limit" => 8192,
               "search_max_oversampling" => 4,
               "search_max_hnsw_ef" => 512,
               "upsert_max_batchsize" => 256,
               "filter_max_conditions" => 64,
               "condition_max_size" => 4096,
               "max_points_count" => 1_500_000,
               "max_timeout" => 30,
               "search_max_batchsize" => 8
             }

      refute Map.has_key?(QdrantLayout.desired_strict(:cloud), "search_allow_exact")
      refute Map.has_key?(QdrantLayout.desired_strict(:cloud), "read_rate_limit")
      refute Map.has_key?(QdrantLayout.desired_strict(:cloud), "write_rate_limit")
    end

    # A self-hoster's collection can outgrow any number picked from our prod.
    test "self-host: none" do
      assert QdrantLayout.desired_strict(:self_host) == %{}
    end

    test "desired/4 adds them on cloud next to the guards; self-host is unchanged" do
      cloud = QdrantLayout.desired(@v1182, nil, true, :cloud)["strict_mode_config"]
      assert cloud["max_query_limit"] == 8192
      assert cloud["enabled"] == true
      assert cloud["max_disk_usage_percent"] == 85

      assert QdrantLayout.desired(@v1182, nil, true, :self_host) == QdrantLayout.desired(@v1182)
    end

    # The kill switch lifts every refusal we set. A PATCH null cannot clear a
    # strict field (`x.or(self.x)` merge), so each goes to a ceiling no
    # request reaches, including the byte breakers an earlier config or a
    # hand PATCH may have left.
    test "strict mode off on cloud lifts the guards and every breaker" do
      off = QdrantLayout.desired(@v1182, nil, false, :cloud)["strict_mode_config"]

      assert off["max_disk_usage_percent"] == 100
      assert off["max_resident_memory_percent"] == 100
      refute Map.has_key?(off, "enabled")

      for field <- Map.keys(QdrantLayout.desired_strict(:cloud)) do
        assert is_number(off[field]) and off[field] >= 2_147_483_647, field
      end

      assert off["max_collection_payload_size_bytes"] == 2 ** 53 - 1
      assert off["max_collection_vector_size_bytes"] == 2 ** 53 - 1
    end

    test "strict mode off on self-host still sends only the two guards" do
      assert QdrantLayout.desired(@v1182, nil, false, :self_host)["strict_mode_config"] == %{
               "max_disk_usage_percent" => 100,
               "max_resident_memory_percent" => 100
             }
    end

    test "an applied cloud config is no drift" do
      config =
        applied(@prod_info)["config"]
        |> update_in(["strict_mode_config"], &Map.merge(&1, QdrantLayout.desired_strict(:cloud)))

      assert QdrantLayout.diff(config, QdrantLayout.desired(@v1182, nil, true, :cloud)) == %{}
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

      # float32 (no datatype) until the v5 payload format is on.
      assert body["vectors"]["dense"] == %{
               "size" => 1024,
               "distance" => "Cosine",
               "on_disk" => true
             }

      assert QdrantLayout.create_params(1024, true)["vectors"]["dense"]["datatype"] == "float16"

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
