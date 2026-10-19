defmodule Engram.PromEx.QdrantCollectionTest do
  # async: false — the poller takes a cluster-wide :global name.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Engram.PromEx.Qdrant, as: Plugin
  alias Engram.ServiceConfig

  @info "test/support/fixtures/qdrant/collection_info_prod_2026_10_18.json"
        |> File.read!()
        |> Jason.decode!()

  @memory "test/support/fixtures/qdrant/collection_memory_prod_2026_10_18.json"
          |> File.read!()
          |> Jason.decode!()

  @collection_event [:engram, :qdrant, :collection]
  @ram_event [:engram, :qdrant, :memory]
  @disk_event [:engram, :qdrant, :disk]
  @pressure_event [:engram, :qdrant, :pressure]
  @limit_event [:engram, :qdrant, :strict_limit]
  @reserve_event [:engram, :qdrant, :reserve]

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    ServiceConfig.put_override(:qdrant_collection_metrics, true)
    :global.unregister_name({Plugin, :collection_poller})
    Engram.Vector.Qdrant.forget_pressure()
    on_exit(&Engram.Vector.Qdrant.forget_pressure/0)
    # Version is node-cached per base URL; a reused Bypass port must not leak it.
    url = "http://localhost:#{bypass.port}"
    Engram.Cache.evict_local(:qdrant_version, url)
    on_exit(fn -> Engram.Cache.evict_local(:qdrant_version, url) end)

    test_pid = self()
    ref = make_ref()

    :telemetry.attach_many(
      {__MODULE__, ref},
      [@collection_event, @ram_event, @disk_event, @pressure_event, @limit_event, @reserve_event],
      fn e, m, meta, _ -> send(test_pid, {e, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    %{bypass: bypass}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp stub_info(bypass, info \\ @info) do
    Bypass.stub(bypass, "GET", "/sys_metrics", &Plug.Conn.send_resp(&1, 404, ""))
    Bypass.stub(bypass, "GET", "/metrics", &Plug.Conn.send_resp(&1, 404, ""))
    # Pre-1.18.1: no strict-mode limit to keep in step, so no PATCH.
    Bypass.stub(bypass, "GET", "/", &json(&1, 200, %{version: "1.17.1"}))

    Bypass.stub(bypass, "GET", "/collections/engram_notes", fn conn ->
      json(conn, 200, %{result: info, status: "ok"})
    end)
  end

  test "declares the gauges with no tenant labels" do
    metrics =
      Plugin.polling_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)

    names = Enum.map(metrics, & &1.name)

    for n <- [
          [:engram, :prom_ex, :qdrant, :collection, :green],
          [:engram, :prom_ex, :qdrant, :optimizer, :ok],
          [:engram, :prom_ex, :qdrant, :last_poll, :timestamp, :seconds],
          [:engram, :prom_ex, :qdrant, :points],
          [:engram, :prom_ex, :qdrant, :disk, :bytes],
          [:engram, :prom_ex, :qdrant, :ram, :bytes],
          [:engram, :prom_ex, :qdrant, :pressure, :percent],
          [:engram, :prom_ex, :qdrant, :strict_limit, :percent],
          [:engram, :prom_ex, :qdrant, :reserve, :bytes]
        ] do
      assert n in names
    end

    assert Enum.flat_map(metrics, & &1.tags) |> Enum.uniq() |> Enum.sort() == [:component, :kind]
  end

  test "declares the backpressure counter tagged by reason only" do
    metrics =
      Plugin.event_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)

    counter =
      Enum.find(metrics, &(&1.name == [:engram, :prom_ex, :qdrant, :backpressure, :total]))

    assert %Telemetry.Metrics.Counter{tags: [:reason]} = counter
    assert counter.event_name == [:engram, :qdrant, :backpressure]
  end

  test "publishes disk pressure percent from /sys_metrics", %{bypass: bypass} do
    Bypass.stub(bypass, "GET", "/collections/engram_notes", fn conn ->
      json(conn, 200, %{result: @info})
    end)

    Bypass.stub(
      bypass,
      "GET",
      "/collections/engram_notes/memory",
      &Plug.Conn.send_resp(&1, 404, "")
    )

    Bypass.stub(bypass, "GET", "/metrics", &Plug.Conn.send_resp(&1, 404, ""))
    Bypass.stub(bypass, "GET", "/", &json(&1, 200, %{version: "1.17.1"}))

    Bypass.stub(bypass, "GET", "/sys_metrics", fn conn ->
      Plug.Conn.send_resp(conn, 200, """
      kubelet_volume_stats_capacity_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} 8.37e+09
      kubelet_volume_stats_used_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} 4.35e+09
      """)
    end)

    Plugin.execute_collection_metrics()
    assert_receive {@pressure_event, %{percent: 51}, %{kind: "disk"}}
    # Heap is unknown without QDRANT_MEMORY_LIMIT_BYTES: no sample, not a 0.
    refute_receive {@pressure_event, _, %{kind: "heap"}}
  end

  test "sets collection + memory gauges from the 1.18 responses", %{bypass: bypass} do
    stub_info(bypass)

    Bypass.stub(bypass, "GET", "/collections/engram_notes/memory", fn conn ->
      json(conn, 200, %{result: @memory, status: "ok"})
    end)

    assert :ok = Plugin.execute_collection_metrics()

    assert_receive {@collection_event, %{green: 1, optimizer_ok: 1, points: 447_012, segments: 6},
                    %{}}

    assert_receive {@disk_event, %{bytes: 4_890_000_000}, %{}}

    ram =
      for _ <- 1..7, into: %{} do
        assert_receive {@ram_event, %{ram_bytes: b}, %{component: c}}
        {c, b}
      end

    assert ram == %{
             "total" => 657_000_000,
             "dense" => 1_000_000,
             "sparse_index" => 419_000_000,
             "payload_index" => 140_000_000,
             "payload" => 0,
             "quantized" => 59_000_000,
             "id_tracker" => 19_000_000
           }
  end

  test "a yellow collection with a failing optimizer reads 0", %{bypass: bypass} do
    stub_info(bypass, %{@info | "status" => "yellow", "optimizer_status" => %{"error" => "x"}})

    Bypass.stub(bypass, "GET", "/collections/engram_notes/memory", fn conn ->
      json(conn, 200, %{result: @memory})
    end)

    Plugin.execute_collection_metrics()
    assert_receive {@collection_event, %{green: 0, optimizer_ok: 0}, _}
  end

  test "a 404 on /memory (pre-1.18 Qdrant) still reports the collection", %{bypass: bypass} do
    stub_info(bypass)

    Bypass.stub(bypass, "GET", "/collections/engram_notes/memory", fn conn ->
      Plug.Conn.send_resp(conn, 404, "")
    end)

    assert :ok = Plugin.execute_collection_metrics()
    assert_receive {@collection_event, %{points: 447_012}, _}
    refute_receive {@disk_event, _, _}
    refute_receive {@ram_event, _, _}
  end

  test "an HTTP failure skips the tick instead of raising", %{bypass: bypass} do
    Bypass.down(bypass)

    log = capture_log(fn -> assert :ok = Plugin.execute_collection_metrics() end)
    assert log =~ "qdrant collection poll skipped"
    refute_receive {@collection_event, _, _}
  end

  # Every node publishes the read-only gauges (a frozen boot value on a
  # non-poller masks max()/min() alerts); only the :global poller PATCHes.
  test "a non-poller node publishes live gauges but never PATCHes", %{bypass: bypass} do
    test_pid = self()
    ServiceConfig.put_override(:qdrant_memory_limit_bytes, 2 * 1024 * 1024 * 1024)
    ServiceConfig.put_override(:qdrant_reconcile_config, true)

    # 1.18.2 + a fixture lacking our guards: the poller WOULD PATCH here.
    Bypass.stub(bypass, "GET", "/", &json(&1, 200, %{version: "1.18.2"}))
    Bypass.stub(bypass, "GET", "/metrics", &Plug.Conn.send_resp(&1, 404, ""))

    Bypass.stub(bypass, "GET", "/sys_metrics", fn conn ->
      Plug.Conn.send_resp(conn, 200, """
      kubelet_volume_stats_capacity_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} 8.37e+09
      kubelet_volume_stats_used_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} 4.35e+09
      """)
    end)

    # Qdrant enforces 81/83; this node would compute 79/87. The gauge must
    # report what is applied, so a failed PATCH or a fallback 85 on one node
    # cannot mislead max().
    applied =
      put_in(@info, ["config", "strict_mode_config"], %{
        "enabled" => true,
        "max_disk_usage_percent" => 81,
        "max_resident_memory_percent" => 83
      })

    Bypass.stub(bypass, "GET", "/collections/engram_notes", fn conn ->
      json(conn, 200, %{result: applied})
    end)

    Bypass.stub(bypass, "GET", "/collections/engram_notes/memory", fn conn ->
      json(conn, 200, %{result: @memory})
    end)

    {:ok, patches} = Agent.start_link(fn -> 0 end)

    Bypass.stub(bypass, "PATCH", "/collections/engram_notes", fn conn ->
      Agent.update(patches, &(&1 + 1))
      send(test_pid, :patched)
      json(conn, 200, %{result: true})
    end)

    other =
      spawn(fn ->
        :global.register_name({Plugin, :collection_poller}, self())
        receive do: (:stop -> :ok)
      end)

    on_exit(fn -> send(other, :stop) end)
    Process.sleep(20)

    assert :ok = Plugin.execute_collection_metrics()

    assert_receive {@collection_event, %{green: 1, optimizer_ok: 1, points: 447_012, segments: 6},
                    %{}}

    assert_receive {@disk_event, %{bytes: 4_890_000_000}, %{}}
    assert_receive {@ram_event, %{ram_bytes: 657_000_000}, %{component: "total"}}
    assert_receive {@pressure_event, %{percent: 51}, %{kind: "disk"}}
    assert_receive {@limit_event, %{percent: 81}, %{kind: "disk"}}
    assert_receive {@limit_event, %{percent: 83}, %{kind: "heap"}}
    refute_received {@limit_event, %{percent: 79}, _}
    refute_received {@limit_event, %{percent: 87}, _}
    assert_receive {@reserve_event, %{bytes: 268_435_456}, %{kind: "heap"}}
    refute_receive :patched
    assert Agent.get(patches, & &1) == 0
  end

  # Limits follow growth and resizes without a deploy: each tick recomputes
  # them from the reserve and PATCHes strict mode only when a value moved.
  test "keeps strict-mode limits in step with the volume, PATCHing only on change",
       %{bypass: bypass} do
    test_pid = self()
    ServiceConfig.put_override(:qdrant_memory_limit_bytes, 2 * 1024 * 1024 * 1024)
    ServiceConfig.put_override(:qdrant_reconcile_config, true)
    {:ok, info} = Agent.start_link(fn -> @info end)

    Bypass.stub(bypass, "GET", "/", &json(&1, 200, %{version: "1.18.2"}))
    Bypass.stub(bypass, "GET", "/metrics", &Plug.Conn.send_resp(&1, 404, ""))

    Bypass.stub(bypass, "GET", "/collections/engram_notes", fn conn ->
      json(conn, 200, %{result: Agent.get(info, & &1)})
    end)

    Bypass.stub(bypass, "GET", "/collections/engram_notes/memory", fn conn ->
      json(conn, 200, %{result: @memory})
    end)

    Bypass.stub(bypass, "GET", "/sys_metrics", fn conn ->
      Plug.Conn.send_resp(conn, 200, """
      kubelet_volume_stats_capacity_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} 8.37e+09
      kubelet_volume_stats_used_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} 4.35e+09
      """)
    end)

    Bypass.stub(bypass, "PATCH", "/collections/engram_notes", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      send(test_pid, {:patch, body})

      Agent.update(info, fn i ->
        update_in(i, ["config", "strict_mode_config"], &Map.merge(&1, body["strict_mode_config"]))
      end)

      json(conn, 200, %{result: true})
    end)

    # The name starts free: this tick registers AND reconciles.
    assert :global.whereis_name({Plugin, :collection_poller}) == :undefined
    Plugin.execute_collection_metrics()
    assert :global.whereis_name({Plugin, :collection_poller}) == self()

    assert_receive {:patch,
                    %{
                      "strict_mode_config" => %{
                        "enabled" => true,
                        "max_disk_usage_percent" => 79,
                        "max_resident_memory_percent" => 87
                      }
                    }}

    # Before the PATCH lands, Qdrant applies no limit: none is published.
    refute_received {@limit_event, _, _}
    assert_receive {@reserve_event, %{bytes: 1_711_500_000}, %{kind: "disk"}}
    assert_receive {@reserve_event, %{bytes: 268_435_456}, %{kind: "heap"}}

    Engram.Vector.Qdrant.forget_pressure()
    Plugin.execute_collection_metrics()
    refute_receive {:patch, _}
    assert_received {@limit_event, %{percent: 79}, %{kind: "disk"}}
    assert_received {@limit_event, %{percent: 87}, %{kind: "heap"}}
  end

  test "QDRANT_RECONCILE_CONFIG=false: the poller never PATCHes", %{bypass: bypass} do
    test_pid = self()
    ServiceConfig.put_override(:qdrant_reconcile_config, false)

    # 1.18.2 + a fixture whose strict mode lacks our guards: without the
    # switch this tick WOULD PATCH (see the "keeps strict-mode limits" test).
    Bypass.stub(bypass, "GET", "/", &json(&1, 200, %{version: "1.18.2"}))
    Bypass.stub(bypass, "GET", "/sys_metrics", &Plug.Conn.send_resp(&1, 404, ""))
    Bypass.stub(bypass, "GET", "/metrics", &Plug.Conn.send_resp(&1, 404, ""))

    Bypass.stub(bypass, "GET", "/collections/engram_notes", fn conn ->
      json(conn, 200, %{result: @info})
    end)

    Bypass.stub(bypass, "GET", "/collections/engram_notes/memory", fn conn ->
      json(conn, 200, %{result: @memory})
    end)

    Bypass.stub(bypass, "PATCH", "/collections/engram_notes", fn conn ->
      send(test_pid, :patched)
      json(conn, 200, %{result: true})
    end)

    Plugin.execute_collection_metrics()
    assert_receive {@collection_event, _, _}
    refute_receive :patched
  end

  test "1.19.2: one PATCH, then quiet; no disk strict-limit gauge", %{bypass: bypass} do
    test_pid = self()
    ServiceConfig.put_override(:qdrant_reconcile_config, true)
    {:ok, info} = Agent.start_link(fn -> @info end)

    Bypass.stub(bypass, "GET", "/", &json(&1, 200, %{version: "1.19.2"}))
    Bypass.stub(bypass, "GET", "/metrics", &Plug.Conn.send_resp(&1, 404, ""))
    # Quotas unset (disabled): 1.19 enforces no disk limit at all.
    Bypass.stub(bypass, "GET", "/quotas", &json(&1, 200, %{result: %{config: %{enabled: false}}}))

    Bypass.stub(bypass, "GET", "/sys_metrics", fn conn ->
      Plug.Conn.send_resp(conn, 200, """
      kubelet_volume_stats_capacity_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} 8.37e+09
      kubelet_volume_stats_used_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} 4.35e+09
      """)
    end)

    Bypass.stub(bypass, "GET", "/collections/engram_notes", fn conn ->
      json(conn, 200, %{result: Agent.get(info, & &1)})
    end)

    Bypass.stub(bypass, "GET", "/collections/engram_notes/memory", fn conn ->
      json(conn, 200, %{result: @memory})
    end)

    # 1.19 accepts max_disk_usage_percent with a 200 and discards it.
    Bypass.stub(bypass, "PATCH", "/collections/engram_notes", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      strict = Jason.decode!(raw)["strict_mode_config"]
      send(test_pid, {:patch, strict})
      kept = Map.drop(strict, ["max_disk_usage_percent"])

      Agent.update(info, fn i ->
        update_in(i, ["config", "strict_mode_config"], &Map.merge(&1, kept))
      end)

      json(conn, 200, %{result: true})
    end)

    Plugin.execute_collection_metrics()
    assert_receive {:patch, %{"enabled" => true, "max_resident_memory_percent" => 85}}
    # The app-side disk reading still feeds the preflight.
    assert_received {@pressure_event, %{percent: 51}, %{kind: "disk"}}

    Engram.Vector.Qdrant.forget_pressure()
    Plugin.execute_collection_metrics()
    refute_receive {:patch, _}
    assert_received {@limit_event, %{percent: 85}, %{kind: "heap"}}
    refute_received {@limit_event, _, %{kind: "disk"}}
  end

  test "1.19.2 with /quotas: gauges report the quota limits, poller keeps them in step",
       %{bypass: bypass} do
    test_pid = self()
    ServiceConfig.put_override(:qdrant_reconcile_config, true)
    ServiceConfig.put_override(:qdrant_manage_quotas, true)
    ServiceConfig.put_override(:qdrant_memory_limit_bytes, 2 * 1024 * 1024 * 1024)
    {:ok, quotas} = Agent.start_link(fn -> %{"enabled" => false} end)

    # Strict heap already applied at the computed 87: no strict PATCH.
    applied =
      put_in(@info, ["config", "strict_mode_config"], %{
        "enabled" => true,
        "max_resident_memory_percent" => 87
      })

    Bypass.stub(bypass, "GET", "/", &json(&1, 200, %{version: "1.19.2"}))
    Bypass.stub(bypass, "GET", "/metrics", &Plug.Conn.send_resp(&1, 404, ""))

    Bypass.stub(bypass, "GET", "/sys_metrics", fn conn ->
      Plug.Conn.send_resp(conn, 200, """
      kubelet_volume_stats_capacity_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} 8.37e+09
      kubelet_volume_stats_used_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} 4.35e+09
      """)
    end)

    Bypass.stub(bypass, "GET", "/collections/engram_notes", &json(&1, 200, %{result: applied}))

    Bypass.stub(bypass, "GET", "/collections/engram_notes/memory", fn conn ->
      json(conn, 200, %{result: @memory})
    end)

    Bypass.stub(bypass, "PATCH", "/collections/engram_notes", fn conn ->
      send(test_pid, :patched)
      json(conn, 200, %{result: true})
    end)

    Bypass.stub(bypass, "GET", "/quotas", fn conn ->
      json(conn, 200, %{result: %{config: Agent.get(quotas, & &1)}})
    end)

    Bypass.stub(bypass, "PUT", "/quotas", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      send(test_pid, {:put_quotas, body})
      Agent.update(quotas, fn _ -> body end)
      json(conn, 200, %{result: true})
    end)

    Plugin.execute_collection_metrics()

    assert_receive {:put_quotas,
                    %{
                      "enabled" => true,
                      "max_disk_usage_percent" => 79,
                      "max_resident_memory_percent" => 87
                    }}

    # Before the PUT lands, only the strict heap limit is enforced.
    assert_received {@limit_event, %{percent: 87}, %{kind: "heap"}}
    refute_received {@limit_event, _, %{kind: "disk"}}

    Engram.Vector.Qdrant.forget_pressure()
    Plugin.execute_collection_metrics()
    refute_receive {:put_quotas, _}
    refute_received :patched
    assert_received {@limit_event, %{percent: 79}, %{kind: "disk"}}
    assert_received {@limit_event, %{percent: 87}, %{kind: "heap"}}
  end

  # The freshness signal infra filters on: a node whose health GET fails must
  # not keep looking current, or its frozen optimizer_ok=1 masks the alert.
  test "a good poll stamps last_poll; a failed poll after it does not", %{bypass: bypass} do
    {:ok, status} = Agent.start_link(fn -> 200 end)
    stub_info(bypass)

    Bypass.stub(bypass, "GET", "/collections/engram_notes", fn conn ->
      json(conn, Agent.get(status, & &1), %{result: @info})
    end)

    Bypass.stub(bypass, "GET", "/collections/engram_notes/memory", fn conn ->
      json(conn, 200, %{result: @memory})
    end)

    Plugin.execute_collection_metrics()
    assert_receive {@collection_event, %{polled_at: ts}, _}
    assert_in_delta ts, System.os_time(:second), 5

    Agent.update(status, fn _ -> 503 end)
    log = capture_log(fn -> Plugin.execute_collection_metrics() end)
    assert log =~ "qdrant collection poll skipped"
    refute_receive {@collection_event, _, _}
  end

  # 4 GETs per node per tick: /memory once (shared by the gauges and the
  # strict limits), the version once per cache TTL.
  test "fetches /memory once per tick and the version once across ticks", %{bypass: bypass} do
    {:ok, hits} = Agent.start_link(fn -> %{} end)
    count = fn key -> Agent.update(hits, &Map.update(&1, key, 1, fn n -> n + 1 end)) end

    Bypass.stub(bypass, "GET", "/sys_metrics", &Plug.Conn.send_resp(&1, 404, ""))
    Bypass.stub(bypass, "GET", "/metrics", &Plug.Conn.send_resp(&1, 404, ""))

    Bypass.stub(bypass, "GET", "/", fn conn ->
      count.(:version)
      json(conn, 200, %{version: "1.17.1"})
    end)

    Bypass.stub(bypass, "GET", "/collections/engram_notes", &json(&1, 200, %{result: @info}))

    Bypass.stub(bypass, "GET", "/collections/engram_notes/memory", fn conn ->
      count.(:memory)
      json(conn, 200, %{result: @memory})
    end)

    Plugin.execute_collection_metrics()
    Engram.Vector.Qdrant.forget_pressure()
    Plugin.execute_collection_metrics()

    assert Agent.get(hits, & &1) == %{memory: 2, version: 1}
  end

  # A raise in one stage (here a malformed shared /memory report) skips only
  # that stage: health, the timestamp and pressure still publish.
  test "a malformed /memory body cannot suppress health or pressure", %{bypass: bypass} do
    stub_info(bypass)

    Bypass.stub(bypass, "GET", "/sys_metrics", fn conn ->
      Plug.Conn.send_resp(conn, 200, """
      kubelet_volume_stats_capacity_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} 8.37e+09
      kubelet_volume_stats_used_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} 4.35e+09
      """)
    end)

    Bypass.stub(bypass, "GET", "/collections/engram_notes/memory", fn conn ->
      json(conn, 200, %{result: %{"total" => []}})
    end)

    log = capture_log(fn -> assert :ok = Plugin.execute_collection_metrics() end)
    assert log =~ "qdrant memory poll skipped"
    assert_receive {@collection_event, %{optimizer_ok: 1, polled_at: _}, _}
    assert_receive {@pressure_event, %{percent: 51}, %{kind: "disk"}}
  end
end
