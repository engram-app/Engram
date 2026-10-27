defmodule Engram.Vector.QdrantReconcileTest do
  use ExUnit.Case, async: true

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  @prod_info "test/support/fixtures/qdrant/collection_info_prod_2026_10_18.json"
             |> File.read!()
             |> Jason.decode!()

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    # Off suite-wide (config/test.exs) so unrelated Bypass suites see no PATCH.
    ServiceConfig.put_override(:qdrant_reconcile_config, true)
    %{bypass: bypass}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp stub_version(bypass, version) do
    Bypass.stub(bypass, "GET", "/", fn conn ->
      json(conn, 200, %{title: "qdrant - vector search engine", version: version})
    end)
  end

  # A stateful fake: GET returns `info`, PATCH merges the body into it the way
  # Qdrant does (see collection_meta_ops.rs update_collection) and records it.
  # `dropped`: strict-mode fields the fake server accepts with 200 and then
  # discards, the way Qdrant 1.19 treats `max_disk_usage_percent`.
  defp fake_collection(bypass, col, info, dropped \\ []) do
    test_pid = self()
    {:ok, agent} = Agent.start_link(fn -> info end)

    Bypass.stub(bypass, "GET", "/collections/#{col}", fn conn ->
      json(conn, 200, %{result: Agent.get(agent, & &1)})
    end)

    Bypass.stub(bypass, "PATCH", "/collections/#{col}", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      send(test_pid, {:patch, body})
      Agent.update(agent, &apply_patch(&1, body, dropped))
      json(conn, 200, %{result: true, status: "ok"})
    end)
  end

  defp apply_patch(info, body, dropped) do
    body = update_in(body, [Access.key("strict_mode_config", %{})], &Map.drop(&1, dropped))

    Enum.reduce(body, info, fn
      {"vectors", v}, acc ->
        update_in(acc, ["config", "params", "vectors"], &deep_merge(&1, v))

      {"sparse_vectors", v}, acc ->
        update_in(acc, ["config", "params", "sparse_vectors"], &deep_merge(&1, v))

      {"hnsw_config", v}, acc ->
        update_in(acc, ["config", "hnsw_config"], &deep_merge(&1, v))

      {"optimizers_config", v}, acc ->
        update_in(acc, ["config", "optimizer_config"], &deep_merge(&1, v))

      {"strict_mode_config", v}, acc ->
        update_in(acc, ["config", "strict_mode_config"], &deep_merge(&1 || %{}, v))
    end)
  end

  defp deep_merge(a, b),
    do:
      Map.merge(a, b, fn _k, x, y -> if is_map(x) and is_map(y), do: deep_merge(x, y), else: y end)

  @gib 1024 * 1024 * 1024

  defp stub_memory(bypass, col, disk_bytes) do
    Bypass.stub(bypass, "GET", "/collections/#{col}/memory", fn conn ->
      json(conn, 200, %{result: %{total: %{disk_bytes: disk_bytes, ram_bytes: 0}}})
    end)
  end

  defp stub_index_creates(bypass, col) do
    Bypass.stub(bypass, "PUT", "/collections/#{col}/index", fn conn ->
      json(conn, 200, %{status: "ok"})
    end)
  end

  defp stub_no_memory(bypass, col) do
    Bypass.stub(bypass, "GET", "/collections/#{col}/memory", fn conn ->
      Plug.Conn.send_resp(conn, 404, "")
    end)
  end

  # Qdrant Cloud's /sys_metrics, Prometheus text.
  defp stub_sys_metrics(bypass, capacity, used) do
    Bypass.stub(bypass, "GET", "/sys_metrics", fn conn ->
      Plug.Conn.send_resp(conn, 200, """
      # TYPE kubelet_volume_stats_capacity_bytes gauge
      kubelet_volume_stats_capacity_bytes{namespace="q",persistentvolumeclaim="qdrant-storage-qdrant-0"} #{capacity}
      kubelet_volume_stats_used_bytes{namespace="q",persistentvolumeclaim="qdrant-storage-qdrant-0"} #{used}
      kubelet_volume_stats_capacity_bytes{namespace="q",persistentvolumeclaim="qdrant-snapshots-qdrant-0"} 1
      kubelet_volume_stats_used_bytes{namespace="q",persistentvolumeclaim="qdrant-snapshots-qdrant-0"} 1
      """)
    end)
  end

  defp stub_no_sys_metrics(bypass) do
    Bypass.stub(bypass, "GET", "/sys_metrics", fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
  end

  defp attach(event) do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      event,
      fn e, m, meta, _ -> send(test_pid, {e, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
  end

  # Strict-mode limits derive from an absolute reserve (QdrantLayout.strict_limits/2).
  defp strict(disk, heap) do
    %{
      "strict_mode_config" => %{
        "enabled" => true,
        "max_disk_usage_percent" => disk,
        "max_resident_memory_percent" => heap
      }
    }
  end

  @optimizers %{"optimizers_config" => %{"max_optimization_threads" => 1}}
  @on_disk %{
    "vectors" => %{"dense" => %{"on_disk" => true}},
    "sparse_vectors" => %{"keyword" => %{"modifier" => "idf", "index" => %{"on_disk" => true}}}
  }

  test "today's prod numbers: all three groups apply", %{bypass: bypass} do
    attach([:engram, :qdrant, :headroom_gate])
    stub_version(bypass, "1.18.2")
    ServiceConfig.put_override(:qdrant_memory_limit_bytes, 2 * @gib)
    fake_collection(bypass, "engram_notes", @prod_info)
    # Measured 2026-10-18: volume 8.37 GB, 4.35 GB used, collection 4.89 GB.
    # Free 4.02 GB >= half the collection; projected peak 4.35 + 0.35 * 4.89
    # = 6.06 GB = 72.4% of the volume, under the 80% ceiling.
    stub_memory(bypass, "engram_notes", 4_890_000_000)
    stub_sys_metrics(bypass, 8_370_000_000, 4_350_000_000)

    assert {:ok, changed} = Qdrant.reconcile_config("engram_notes")
    assert Enum.sort(changed) == ~w(optimizers_config sparse_vectors strict_mode_config vectors)

    # Disk reserve 0.35 * 4.89 GB = 1.71 GB -> 79%; heap 2 GiB - 256 MiB -> 87%.
    assert_receive {:patch, strict}
    assert strict == strict(79, 87)
    assert_receive {:patch, @optimizers}
    assert_receive {:patch, @on_disk}

    free = 8_370_000_000 - 4_350_000_000

    assert_receive {[:engram, :qdrant, :headroom_gate],
                    %{free_bytes: ^free, collection_bytes: 4_890_000_000},
                    %{decision: :apply, source: :sys_metrics}}
  end

  test "a tight volume: strict + optimizers apply, on-disk is deferred", %{bypass: bypass} do
    attach([:engram, :qdrant, :headroom_gate])
    stub_version(bypass, "1.18.2")
    fake_collection(bypass, "engram_notes", @prod_info)
    # Projected peak 6.0 + 0.35 * 4.89 = 7.71 GB = 92% of 8.37 GB.
    stub_memory(bypass, "engram_notes", 4_890_000_000)
    stub_sys_metrics(bypass, 8_370_000_000, 6_000_000_000)

    assert {:ok, changed} = Qdrant.reconcile_config("engram_notes")
    assert Enum.sort(changed) == ~w(optimizers_config strict_mode_config)

    assert_receive {:patch, strict}
    assert strict == strict(79, 85)
    assert_receive {:patch, @optimizers}
    refute_receive {:patch, _}

    assert_receive {[:engram, :qdrant, :headroom_gate], _,
                    %{decision: :defer, source: :sys_metrics}}

    # Second boot: nothing to PATCH; the deferred group stays deferred.
    assert {:ok, []} = Qdrant.reconcile_config("engram_notes")
    refute_receive {:patch, _}
  end

  test "with headroom all three groups apply in order, then nothing", %{bypass: bypass} do
    stub_version(bypass, "1.18.2")
    fake_collection(bypass, "engram_notes", @prod_info)
    stub_memory(bypass, "engram_notes", 4_890_000_000)
    stub_sys_metrics(bypass, 16 * @gib, 4_890_000_000)

    assert {:ok, changed} = Qdrant.reconcile_config("engram_notes")
    assert Enum.sort(changed) == ~w(optimizers_config sparse_vectors strict_mode_config vectors)

    assert_receive {:patch, strict}
    assert strict == strict(90, 85)
    assert_receive {:patch, @optimizers}
    assert_receive {:patch, @on_disk}

    assert {:ok, []} = Qdrant.reconcile_config("engram_notes")
    refute_receive {:patch, _}
  end

  test "self-host (no /sys_metrics): a collection under 1 GiB gets on-disk", %{bypass: bypass} do
    stub_version(bypass, "1.18.2")
    fake_collection(bypass, "obsidian_notes", @prod_info)
    stub_memory(bypass, "obsidian_notes", 200_000_000)
    stub_no_sys_metrics(bypass)

    assert {:ok, changed} = Qdrant.reconcile_config("obsidian_notes")
    assert "vectors" in changed
  end

  test "self-host (no /sys_metrics): a collection over 1 GiB defers on-disk", %{bypass: bypass} do
    attach([:engram, :qdrant, :headroom_gate])
    stub_version(bypass, "1.18.2")
    fake_collection(bypass, "obsidian_notes", @prod_info)
    stub_memory(bypass, "obsidian_notes", 2 * @gib)
    stub_no_sys_metrics(bypass)

    assert {:ok, changed} = Qdrant.reconcile_config("obsidian_notes")
    refute "vectors" in changed
    assert_receive {_, _, %{decision: :defer, source: :self_host_rule}}
  end

  test "on 1.17.1 (CI pin) strict mode is never sent and on-disk defers", %{bypass: bypass} do
    stub_version(bypass, "1.17.1")
    fake_collection(bypass, "obsidian_notes", @prod_info)
    stub_no_memory(bypass, "obsidian_notes")
    stub_no_sys_metrics(bypass)

    assert {:ok, ["optimizers_config"]} = Qdrant.reconcile_config("obsidian_notes")
    assert_receive {:patch, @optimizers}
    refute_receive {:patch, _}
  end

  describe "headroom/2" do
    # Rehearsal on a prod clone: the on-disk rewrite peaked at +0.26x the
    # collection's bytes. The gate needs free >= 0.5x and projects the peak as
    # used + 0.35x (~35% margin), which must stay under 80% of the volume,
    # below strict mode's 85% write cap.
    test "apply needs free >= half the collection AND projected peak under 80%" do
      vol = fn used, cap -> %{used: used, capacity: cap} end

      # projected (40 + 7) / 100 = 0.47, free 60 >= 10
      assert {:apply, :sys_metrics, 60} = Qdrant.headroom(20, vol.(40, 100))
      # projected (72 + 7) / 100 = 0.79
      assert {:apply, :sys_metrics, 28} = Qdrant.headroom(20, vol.(72, 100))
      # projected exactly 0.80 is not under the ceiling
      assert {:defer, :sys_metrics, 27} = Qdrant.headroom(20, vol.(73, 100))
      # projected (5 + 70) / 100 = 0.75 passes, but free 95 < half of 200
      assert {:defer, :sys_metrics, 95} = Qdrant.headroom(200, vol.(5, 100))
    end

    test "today's prod numbers apply (72.4%)" do
      assert {:apply, :sys_metrics, 4_020_000_000} =
               Qdrant.headroom(4_890_000_000, %{used: 4_350_000_000, capacity: 8_370_000_000})
    end

    test "self-host and unknown-size rules" do
      assert {:apply, :self_host_rule, nil} = Qdrant.headroom(@gib - 1, nil)
      assert {:defer, :self_host_rule, nil} = Qdrant.headroom(@gib, nil)
      assert {:defer, :unknown_size, 99} = Qdrant.headroom(nil, %{used: 1, capacity: 100})
    end

    test "parse_volume_stats picks the qdrant-storage PVC" do
      text = """
      # TYPE kubelet_volume_stats_capacity_bytes gauge
      kubelet_volume_stats_capacity_bytes{persistentvolumeclaim="qdrant-snapshots-qdrant-0"} 5e+09
      kubelet_volume_stats_capacity_bytes{namespace="x",persistentvolumeclaim="qdrant-storage-qdrant-0"} 8.37e+09
      kubelet_volume_stats_used_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} 4.35e+09
      kubelet_volume_stats_used_bytes{persistentvolumeclaim="qdrant-snapshots-qdrant-0"} 1
      """

      assert Qdrant.parse_volume_stats(text) == %{used: 4_350_000_000, capacity: 8_370_000_000}
      assert Qdrant.parse_volume_stats("# nothing here\n") == nil

      assert Qdrant.parse_volume_stats(
               ~s|kubelet_volume_stats_used_bytes{persistentvolumeclaim="qdrant-storage-0"} 4\n|
             ) == nil
    end
  end

  # The per-tenant graph follows LEGACY_FILTER_FIELDS: on (the default) a
  # collection may hold legacy `user_id` points and keeps the global graph;
  # off (SaaS prod, the v3 cluster) it moves to m 0 once `u` is is_tenant.
  describe "per-tenant graph (m 0), on once legacy filters are off" do
    @tenant_u %{
      "data_type" => "uuid",
      "params" => %{"type" => "uuid", "is_tenant" => true, "on_disk" => true}
    }

    # The v3 cluster (prod since 2026-10-26) as it was created: the 1.19.2
    # tenant fixture's layout (m 0, payload_m 16, one indexing thread, `u`
    # is_tenant), only the 21 v5 payload indexes, segments capped at 128,000
    # KB, two default segments, f16 sparse values.
    @legacy_index_keys ~w(user_id vault_id path_hmac type_hmac folder_hmac tags_hmac
                          fm_timestamp fm_created)
    @v3_info "test/support/fixtures/qdrant/collection_info_tenant_1_19_2.json"
             |> File.read!()
             |> Jason.decode!()
             |> Map.update!("payload_schema", &Map.drop(&1, @legacy_index_keys))
             |> put_in(["config", "optimizer_config", "max_segment_size"], 128_000)
             |> put_in(["config", "optimizer_config", "default_segment_number"], 2)
             |> put_in(
               ["config", "params", "sparse_vectors", "keyword", "index", "datatype"],
               "float16"
             )

    defp boot_1192(bypass, info) do
      stub_version(bypass, "1.19.2")
      fake_collection(bypass, "engram_notes", info, ["max_disk_usage_percent"])
      stub_memory(bypass, "engram_notes", 100)
      stub_no_sys_metrics(bypass)
      assert {:ok, _} = Qdrant.reconcile_config("engram_notes")
    end

    test "legacy filters on (default): never PATCHes the graph", %{bypass: bypass} do
      boot_1192(bypass, put_in(@prod_info, ["payload_schema", "u"], @tenant_u))
      refute_receive {:patch, %{"hnsw_config" => _}}
    end

    test "legacy filters off, but `u` is not the tenant index: graph untouched",
         %{bypass: bypass} do
      ServiceConfig.put_override(:legacy_filter_fields, false)
      boot_1192(bypass, @prod_info)
      refute_receive {:patch, %{"hnsw_config" => _}}
    end

    test "legacy filters off and `u` is_tenant: m 0 once, then no drift", %{bypass: bypass} do
      ServiceConfig.put_override(:legacy_filter_fields, false)
      boot_1192(bypass, put_in(@prod_info, ["payload_schema", "u"], @tenant_u))

      assert_receive {:patch, %{"hnsw_config" => %{"m" => 0, "payload_m" => 16}}}
      assert {:ok, []} = Qdrant.reconcile_config("engram_notes")
    end

    # Prod's config: LEGACY_FILTER_FIELDS=false on the v3 cluster. The graph
    # it wants is the one v3 was created with, so no reconcile (boot or the
    # poller) ever PATCHes hnsw_config there, and the 0.5 vCPU node never
    # rebuilds its HNSW for this.
    test "the v3 cluster's shape: no hnsw_config PATCH, ever", %{bypass: bypass} do
      ServiceConfig.put_override(:legacy_filter_fields, false)
      assert @v3_info["config"]["hnsw_config"]["m"] == 0
      assert map_size(@v3_info["payload_schema"]) == 21

      boot_1192(bypass, @v3_info)
      assert {:ok, _} = Qdrant.reconcile_config("engram_notes")

      for {:patch, body} <- flush() do
        refute Map.has_key?(body, "hnsw_config"), inspect(body)
        refute Map.has_key?(body, "vectors"), inspect(body)
        refute Map.has_key?(body, "sparse_vectors"), inspect(body)
      end
    end
  end

  describe "Qdrant 1.19+ (disk guard moved to node-wide /quotas)" do
    test "1.19.2: never sends the disk field, converges after one PATCH", %{bypass: bypass} do
      stub_version(bypass, "1.19.2")
      # 1.19 answers 200 to a PATCH carrying max_disk_usage_percent and drops it.
      fake_collection(bypass, "engram_notes", @prod_info, ["max_disk_usage_percent"])
      stub_memory(bypass, "engram_notes", 100)
      stub_no_sys_metrics(bypass)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, changed} = Qdrant.reconcile_config("engram_notes")
          assert "strict_mode_config" in changed
        end)

      assert log =~ "qdrant disk write guard unavailable on 1.19.2"

      assert_receive {:patch, %{"strict_mode_config" => strict}}
      assert strict == %{"enabled" => true, "max_resident_memory_percent" => 85}

      assert {:ok, []} = Qdrant.reconcile_config("engram_notes")
      refute_receive {:patch, %{"strict_mode_config" => _}}
    end

    test "1.21: sends neither guard", %{bypass: bypass} do
      stub_version(bypass, "1.21.0")
      fake_collection(bypass, "engram_notes", @prod_info)
      stub_memory(bypass, "engram_notes", 100)
      stub_no_sys_metrics(bypass)

      assert {:ok, changed} = Qdrant.reconcile_config("engram_notes")
      refute "strict_mode_config" in changed
    end

    test "1.19.2 with QDRANT_STRICT_MODE=false converges too", %{bypass: bypass} do
      ServiceConfig.put_override(:qdrant_strict_mode, false)
      stub_version(bypass, "1.19.2")
      fake_collection(bypass, "engram_notes", @prod_info, ["max_disk_usage_percent"])
      stub_memory(bypass, "engram_notes", 100)
      stub_no_sys_metrics(bypass)

      assert {:ok, _} = Qdrant.reconcile_config("engram_notes")

      assert_receive {:patch,
                      %{"strict_mode_config" => %{"max_resident_memory_percent" => 100} = strict}}

      assert map_size(strict) == 1
      assert {:ok, []} = Qdrant.reconcile_config("engram_notes")
    end
  end

  describe "/quotas (Qdrant 1.19+, QDRANT_MANAGE_QUOTAS)" do
    # GET/PUT /quotas the way 1.19 answers them: PUT replaces the whole
    # QuotaConfig (openapi `update_quotas`), GET returns it under `config`.
    defp fake_quotas(bypass, config \\ %{"enabled" => false}) do
      test_pid = self()
      {:ok, agent} = Agent.start_link(fn -> config end)

      Bypass.stub(bypass, "GET", "/quotas", fn conn ->
        json(conn, 200, %{result: %{config: Agent.get(agent, & &1), usage: %{}}, status: "ok"})
      end)

      Bypass.stub(bypass, "PUT", "/quotas", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        send(test_pid, {:put_quotas, body, conn.query_string})
        Agent.update(agent, fn _ -> body end)
        json(conn, 200, %{result: true, status: "ok"})
      end)

      agent
    end

    @limits %{disk: %{percent: 79, reserve: 1}, heap: %{percent: 87, reserve: 1}}
    @want_quotas %{
      "enabled" => true,
      "max_disk_usage_percent" => 79,
      "max_resident_memory_percent" => 87
    }
    @v1182 Version.parse!("1.18.2")
    @v1192 Version.parse!("1.19.2")

    defp info!(col) do
      {:ok, info} = Qdrant.collection_info(col)
      info
    end

    test "1.19.2 boot: disk + heap go to /quotas, then nothing", %{bypass: bypass} do
      ServiceConfig.put_override(:qdrant_manage_quotas, true)
      ServiceConfig.put_override(:qdrant_memory_limit_bytes, 2 * @gib)
      stub_version(bypass, "1.19.2")
      fake_collection(bypass, "engram_notes", @prod_info, ["max_disk_usage_percent"])
      fake_quotas(bypass)
      stub_memory(bypass, "engram_notes", 4_890_000_000)
      stub_sys_metrics(bypass, 8_370_000_000, 4_350_000_000)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, changed} = Qdrant.reconcile_config("engram_notes")
          assert "quotas" in changed
        end)

      refute log =~ "write guard unavailable"
      assert_receive {:put_quotas, @want_quotas, "wait=true"}

      assert {:ok, []} = Qdrant.reconcile_config("engram_notes")
      refute_receive {:put_quotas, _, _}
    end

    test "poller on 1.19.2: PUTs when a limit moves, idempotent otherwise", %{bypass: bypass} do
      ServiceConfig.put_override(:qdrant_manage_quotas, true)
      fake_collection(bypass, "engram_notes", @prod_info, ["max_disk_usage_percent"])
      fake_quotas(bypass)

      assert :ok =
               Qdrant.reconcile_strict_mode(
                 "engram_notes",
                 info!("engram_notes"),
                 @limits,
                 @v1192
               )

      assert_receive {:put_quotas, @want_quotas, "wait=true"}

      for _ <- 1..3,
          do:
            assert(
              :ok =
                Qdrant.reconcile_strict_mode(
                  "engram_notes",
                  info!("engram_notes"),
                  @limits,
                  @v1192
                )
            )

      refute_receive {:put_quotas, _, _}

      grown = put_in(@limits, [:disk, :percent], 75)

      assert :ok =
               Qdrant.reconcile_strict_mode("engram_notes", info!("engram_notes"), grown, @v1192)

      assert_receive {:put_quotas, %{"max_disk_usage_percent" => 75}, _}
    end

    test "below 1.19 /quotas is never touched", %{bypass: bypass} do
      ServiceConfig.put_override(:qdrant_manage_quotas, true)
      fake_collection(bypass, "engram_notes", @prod_info)
      fake_quotas(bypass)

      assert :ok =
               Qdrant.reconcile_strict_mode(
                 "engram_notes",
                 info!("engram_notes"),
                 @limits,
                 @v1182
               )

      assert_receive {:patch, %{"strict_mode_config" => %{"max_disk_usage_percent" => 79}}}
      refute_receive {:put_quotas, _, _}
    end

    test "unmanaged (the default, shared servers): 1.19 never PUTs /quotas", %{bypass: bypass} do
      fake_collection(bypass, "engram_notes", @prod_info, ["max_disk_usage_percent"])
      fake_quotas(bypass)

      assert :ok =
               Qdrant.reconcile_strict_mode(
                 "engram_notes",
                 info!("engram_notes"),
                 @limits,
                 @v1192
               )

      refute_receive {:put_quotas, _, _}
    end

    test "QDRANT_STRICT_MODE=false sets the quotas to 100/100", %{bypass: bypass} do
      ServiceConfig.put_override(:qdrant_manage_quotas, true)
      ServiceConfig.put_override(:qdrant_strict_mode, false)
      fake_collection(bypass, "engram_notes", @prod_info, ["max_disk_usage_percent"])
      fake_quotas(bypass, @want_quotas)

      assert :ok =
               Qdrant.reconcile_strict_mode(
                 "engram_notes",
                 info!("engram_notes"),
                 @limits,
                 @v1192
               )

      assert_receive {:put_quotas,
                      %{"max_disk_usage_percent" => 100, "max_resident_memory_percent" => 100}, _}
    end

    test "a refused PUT is an error, not a crash", %{bypass: bypass} do
      ServiceConfig.put_override(:qdrant_manage_quotas, true)
      fake_collection(bypass, "engram_notes", @prod_info, ["max_disk_usage_percent"])

      Bypass.stub(bypass, "GET", "/quotas", fn conn ->
        json(conn, 200, %{result: %{config: %{enabled: false}}})
      end)

      Bypass.stub(bypass, "PUT", "/quotas", &json(&1, 403, %{status: %{error: "forbidden"}}))

      assert {:error, {403, _}} =
               Qdrant.reconcile_strict_mode(
                 "engram_notes",
                 info!("engram_notes"),
                 @limits,
                 @v1192
               )
    end

    # Mid-upgrade every node keeps its cached version for up to 10 minutes, so
    # some reconcile as 1.18 and some as 1.19 against the same (1.19) server.
    # They must converge, not undo each other.
    test "mixed fleet (1.18 and 1.19 views of one 1.19 server) does not fight",
         %{bypass: bypass} do
      ServiceConfig.put_override(:qdrant_manage_quotas, true)
      fake_collection(bypass, "engram_notes", @prod_info, ["max_disk_usage_percent"])
      quotas = fake_quotas(bypass)

      for _ <- 1..3, version <- [@v1182, @v1192] do
        assert :ok =
                 Qdrant.reconcile_strict_mode(
                   "engram_notes",
                   info!("engram_notes"),
                   @limits,
                   version
                 )
      end

      # Only the 1.19 view writes /quotas, once.
      assert_received {:put_quotas, @want_quotas, _}
      refute_received {:put_quotas, _, _}
      assert Agent.get(quotas, & &1) == @want_quotas

      # Every strict PATCH, from either view, carries the same heap limit, so
      # the stored value never flips. The 1.18 view re-sends only the disk
      # field 1.19 drops (until its version cache expires); harmless.
      patches = for {:patch, %{"strict_mode_config" => s}} <- flush(), do: s
      assert patches != []
      assert Enum.all?(patches, &(&1["max_resident_memory_percent"] in [nil, 87]))
      refute Enum.any?(patches, &(&1["max_disk_usage_percent"] not in [nil, 79]))

      assert info!("engram_notes")["config"]["strict_mode_config"]["max_resident_memory_percent"] ==
               87

      # Once every node sees 1.19: fully quiet.
      assert :ok =
               Qdrant.reconcile_strict_mode(
                 "engram_notes",
                 info!("engram_notes"),
                 @limits,
                 @v1192
               )

      refute_receive {:patch, _}
      refute_receive {:put_quotas, _, _}
    end

    defp flush do
      receive do
        msg -> [msg | flush()]
      after
        0 -> []
      end
    end
  end

  describe "kill switches" do
    test "QDRANT_RECONCILE_CONFIG=false: no request, no PATCH", %{bypass: bypass} do
      ServiceConfig.put_override(:qdrant_reconcile_config, false)
      Bypass.down(bypass)
      assert {:ok, []} = Qdrant.reconcile_config("engram_notes")
      assert :ok = Qdrant.reconcile_strict_mode("engram_notes", @prod_info, nil)
    end

    test "QDRANT_RECONCILE_ON_DISK=false skips only the on-disk group", %{bypass: bypass} do
      ServiceConfig.put_override(:qdrant_reconcile_on_disk, false)
      stub_version(bypass, "1.18.2")
      fake_collection(bypass, "engram_notes", @prod_info)
      stub_memory(bypass, "engram_notes", 100)
      stub_no_sys_metrics(bypass)

      assert {:ok, changed} = Qdrant.reconcile_config("engram_notes")
      assert Enum.sort(changed) == ~w(optimizers_config strict_mode_config)
    end

    test "QDRANT_STRICT_MODE=false actively disables strict mode", %{bypass: bypass} do
      ServiceConfig.put_override(:qdrant_strict_mode, false)
      stub_version(bypass, "1.18.2")
      fake_collection(bypass, "engram_notes", @prod_info)
      stub_memory(bypass, "engram_notes", 100)
      stub_no_sys_metrics(bypass)

      assert {:ok, _} = Qdrant.reconcile_config("engram_notes")

      assert_receive {:patch,
                      %{
                        "strict_mode_config" =>
                          %{
                            "max_disk_usage_percent" => 100,
                            "max_resident_memory_percent" => 100
                          } = strict
                      }}

      refute Map.has_key?(strict, "enabled")
      refute Map.has_key?(strict, "unindexed_filtering_retrieve")

      # The fixture's Cloud guards survive the merge.
      {:ok, info} = Qdrant.collection_info("engram_notes")
      assert info["config"]["strict_mode_config"]["enabled"] == true
      assert info["config"]["strict_mode_config"]["unindexed_filtering_retrieve"] == false

      # Applied: the next run leaves it alone.
      assert {:ok, []} = Qdrant.reconcile_config("engram_notes")
    end
  end

  test "an unreadable version skips strict mode instead of failing", %{bypass: bypass} do
    Bypass.stub(bypass, "GET", "/", fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
    fake_collection(bypass, "engram_notes", @prod_info)
    stub_no_memory(bypass, "engram_notes")
    stub_no_sys_metrics(bypass)

    assert {:ok, changed} = Qdrant.reconcile_config("engram_notes")
    refute "strict_mode_config" in changed
  end

  test "a rejected PATCH is an error, not a crash", %{bypass: bypass} do
    stub_version(bypass, "1.18.2")

    Bypass.stub(bypass, "GET", "/collections/engram_notes", fn conn ->
      json(conn, 200, %{result: @prod_info})
    end)

    Bypass.stub(bypass, "PATCH", "/collections/engram_notes", fn conn ->
      json(conn, 403, %{status: %{error: "forbidden"}})
    end)

    stub_no_memory(bypass, "engram_notes")
    stub_no_sys_metrics(bypass)

    assert {:error, _} = Qdrant.reconcile_config("engram_notes")
  end

  test "emits a telemetry event when it applies a change", %{bypass: bypass} do
    stub_version(bypass, "1.18.2")
    fake_collection(bypass, "engram_notes", @prod_info)
    stub_memory(bypass, "engram_notes", 100)
    stub_no_sys_metrics(bypass)

    ref = make_ref()
    test_pid = self()

    # Telemetry handlers are global and run in the emitting process. The async
    # qdrant_collection_test reconciles its own 1.19.2 collections at the same
    # time (an `optimizers_config` change, which is what CI received here), so
    # forward only this test's own emit: reconcile_config/1 runs in the caller.
    :telemetry.attach(
      {__MODULE__, ref},
      [:engram, :qdrant, :config_reconciled],
      fn _e, m, meta, _ -> if self() == test_pid, do: send(test_pid, {:reconciled, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    assert {:ok, _} = Qdrant.reconcile_config("engram_notes")
    assert_receive {:reconciled, %{count: 1}, %{changed: changed}}
    assert "vectors" in changed
  end

  test "ensure_collection reconciles an existing collection", %{bypass: bypass} do
    stub_version(bypass, "1.18.2")
    fake_collection(bypass, "engram_notes", @prod_info)
    stub_memory(bypass, "engram_notes", 100)
    stub_no_sys_metrics(bypass)

    Bypass.expect_once(bypass, "PUT", "/collections/engram_notes", fn conn ->
      json(conn, 409, %{status: %{error: "already exists"}})
    end)

    # The prod fixture predates the v5 short-key indexes, which ensure_collection
    # now adds to an existing collection.
    stub_index_creates(bypass, "engram_notes")

    assert :ok = Qdrant.ensure_collection("engram_notes", 1024)
    assert_receive {:patch, %{"vectors" => _}}
  end

  # `QDRANT_STRICT_PROFILE=cloud` reproduces prod's unindexed-filter refusal
  # (#2138). It must land AFTER the payload indexes, or the first filter 400s.
  describe "unindexed filtering on the cloud profile" do
    setup %{bypass: bypass} do
      ServiceConfig.put_override(:qdrant_strict_profile, :cloud)
      stub_version(bypass, "1.18.2")
      stub_memory(bypass, "engram_notes", 100)
      stub_no_sys_metrics(bypass)
      :ok
    end

    defp without_refusal(info),
      do:
        update_in(
          info,
          ["config", "strict_mode_config"],
          &Map.delete(&1, "unindexed_filtering_retrieve")
        )

    test "boot creates the payload indexes, then refuses unindexed reads", %{bypass: bypass} do
      test_pid = self()
      # The v5 short keys are missing from the fixture: index creates happen.
      fake_collection(bypass, "engram_notes", without_refusal(@prod_info))

      Bypass.expect_once(bypass, "PUT", "/collections/engram_notes", fn conn ->
        json(conn, 409, %{status: %{error: "already exists"}})
      end)

      Bypass.stub(bypass, "PUT", "/collections/engram_notes/index", fn conn ->
        send(test_pid, :index)
        json(conn, 200, %{status: "ok"})
      end)

      assert :ok = Qdrant.ensure_collection("engram_notes", 1024)

      msgs = for msg <- flush(), msg == :index or match?({:patch, _}, msg), do: msg

      refusal =
        Enum.find_index(
          msgs,
          &match?(
            {:patch, %{"strict_mode_config" => %{"unindexed_filtering_retrieve" => false}}},
            &1
          )
        )

      assert refusal, "no PATCH set unindexed_filtering_retrieve: false"

      assert :index in Enum.take(msgs, refusal),
             "the refusal was applied before any payload index"

      refute :index in Enum.drop(msgs, refusal)
    end

    test "prod already refuses: re-applying it is idempotent", %{bypass: bypass} do
      fake_collection(bypass, "engram_notes", @prod_info)
      assert {:ok, _} = Qdrant.reconcile_config("engram_notes")
      assert {:ok, []} = Qdrant.reconcile_config("engram_notes")

      {:ok, info} = Qdrant.collection_info("engram_notes")
      assert info["config"]["strict_mode_config"]["unindexed_filtering_retrieve"] == false
      refute Map.has_key?(info["config"]["strict_mode_config"], "unindexed_filtering_update")
    end

    # The boot ensure now runs on every node, web tier included. At prod's
    # flags (LEGACY_FILTER_FIELDS=false on the v3 cluster) it must find every
    # payload index prod already has and create none, and never set
    # `unindexed_filtering_update` (prod leaves it unset). The 2026-10-18
    # fixture predates the v5 indexes, so its schema is the v3 cluster's.
    test "prod flags: the ensure on prod creates no payload index", %{bypass: bypass} do
      test_pid = self()
      ServiceConfig.put_override(:legacy_filter_fields, false)
      prod_v3 = Map.put(@prod_info, "payload_schema", @v3_info["payload_schema"])
      fake_collection(bypass, "engram_notes", prod_v3)

      Bypass.expect_once(bypass, "PUT", "/collections/engram_notes", fn conn ->
        json(conn, 409, %{status: %{error: "already exists"}})
      end)

      Bypass.stub(bypass, "PUT", "/collections/engram_notes/index", fn conn ->
        send(test_pid, :index)
        json(conn, 200, %{status: "ok"})
      end)

      assert :ok = Qdrant.ensure_collection("engram_notes", 1024)
      refute_received :index

      for {:patch, %{"strict_mode_config" => strict}} <- flush() do
        assert Map.get(strict, "unindexed_filtering_retrieve", false) == false
        refute Map.has_key?(strict, "unindexed_filtering_update")
      end
    end

    # The poller runs on its own clock, possibly before the boot ensure made
    # the indexes: it keeps the limits only, never the refusal.
    test "the poller never sets the refusal", %{bypass: bypass} do
      fake_collection(bypass, "engram_notes", without_refusal(@prod_info))

      assert :ok =
               Qdrant.reconcile_strict_mode(
                 "engram_notes",
                 without_refusal(@prod_info),
                 nil,
                 Version.parse!("1.18.2")
               )

      assert_receive {:patch, %{"strict_mode_config" => strict}}
      refute Map.has_key?(strict, "unindexed_filtering_retrieve")
    end
  end

  test "ensure_collection still succeeds when the reconcile fails", %{bypass: bypass} do
    stub_version(bypass, "1.18.2")

    Bypass.stub(bypass, "GET", "/collections/engram_notes", fn conn ->
      json(conn, 200, %{result: @prod_info})
    end)

    Bypass.stub(bypass, "PATCH", "/collections/engram_notes", fn conn ->
      json(conn, 500, %{status: %{error: "nope"}})
    end)

    stub_no_memory(bypass, "engram_notes")
    stub_no_sys_metrics(bypass)

    Bypass.expect_once(bypass, "PUT", "/collections/engram_notes", fn conn ->
      json(conn, 409, %{status: %{error: "already exists"}})
    end)

    # The prod fixture predates the v5 short-key indexes, which ensure_collection
    # now adds to an existing collection.
    stub_index_creates(bypass, "engram_notes")

    assert :ok = Qdrant.ensure_collection("engram_notes", 1024)
  end

  test "a fresh create sends the desired storage params", %{bypass: bypass} do
    test_pid = self()
    stub_version(bypass, "1.18.2")

    Bypass.stub(bypass, "PUT", "/collections/fresh/index", fn conn ->
      Plug.Conn.send_resp(conn, 200, ~s({"status":"ok"}))
    end)

    Bypass.expect_once(bypass, "PUT", "/collections/fresh", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:create, Jason.decode!(raw)})
      json(conn, 200, %{result: true})
    end)

    # After create, the reconcile reads back what was created: only the
    # strict-mode guard (version-gated, so not part of create) is left.
    created =
      @prod_info
      |> put_in(["config", "params", "vectors", "dense", "on_disk"], true)
      |> put_in(["config", "params", "sparse_vectors", "keyword", "index"], %{"on_disk" => true})
      |> put_in(["config", "optimizer_config", "max_optimization_threads"], 1)

    fake_collection(bypass, "fresh", created)
    stub_no_memory(bypass, "fresh")
    stub_no_sys_metrics(bypass)

    assert :ok = Qdrant.ensure_collection("fresh", 1024)
    assert_receive {:create, body}
    assert body["vectors"]["dense"]["on_disk"] == true
    assert body["sparse_vectors"]["keyword"]["index"] == %{"on_disk" => true}
    assert body["optimizers_config"] == %{"max_optimization_threads" => 1}
    assert body["quantization_config"] == %{"binary" => %{"always_ram" => true}}

    assert_receive {:patch, patch}
    assert Map.keys(patch) == ["strict_mode_config"]
  end

  test "deployment: only a Qdrant Cloud host is :cloud" do
    assert Qdrant.deployment("https://abc-123.eu-central-1-0.aws.cloud.qdrant.io:6333") ==
             :cloud

    assert Qdrant.deployment("http://localhost:6333") == :self_host
    assert Qdrant.deployment("http://qdrant:6333") == :self_host
    assert Qdrant.deployment("https://cloud.qdrant.io.evil.test") == :self_host
    assert Qdrant.deployment("") == :self_host
  end

  # A URL without a scheme parses with no host, which silently read as
  # self-host: no breakers, no log (review L4).
  test "deployment: a scheme-less Cloud URL is still :cloud" do
    assert Qdrant.deployment("abc-123.eu-central-1-0.aws.cloud.qdrant.io:6333") == :cloud
    assert Qdrant.deployment("abc-123.aws.cloud.qdrant.io") == :cloud
    assert Qdrant.deployment("localhost:6333") == :self_host
  end

  # QDRANT_STRICT_PROFILE lets staging (self-host) rehearse the Cloud limits.
  test "deployment: the :qdrant_strict_profile override wins over the host" do
    ServiceConfig.put_override(:qdrant_strict_profile, :cloud)
    assert Qdrant.deployment("http://qdrant:6333") == :cloud

    ServiceConfig.put_override(:qdrant_strict_profile, :self_host)
    assert Qdrant.deployment("https://abc.aws.cloud.qdrant.io") == :self_host
    assert Qdrant.deployment_source() == :override
  end
end
