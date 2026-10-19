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

  test "only one process in the cluster polls", %{bypass: bypass} do
    stub_info(bypass)

    Bypass.stub(bypass, "GET", "/collections/engram_notes/memory", fn conn ->
      Plug.Conn.send_resp(conn, 404, "")
    end)

    other =
      spawn(fn ->
        :global.register_name({Plugin, :collection_poller}, self())
        receive do: (:stop -> :ok)
      end)

    on_exit(fn -> send(other, :stop) end)
    Process.sleep(20)

    assert :ok = Plugin.execute_collection_metrics()
    refute_receive {@collection_event, _, _}
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

    Plugin.execute_collection_metrics()

    assert_receive {:patch,
                    %{
                      "strict_mode_config" => %{
                        "enabled" => true,
                        "max_disk_usage_percent" => 79,
                        "max_resident_memory_percent" => 87
                      }
                    }}

    assert_receive {@limit_event, %{percent: 79}, %{kind: "disk"}}
    assert_receive {@limit_event, %{percent: 87}, %{kind: "heap"}}
    assert_receive {@reserve_event, %{bytes: 1_711_500_000}, %{kind: "disk"}}
    assert_receive {@reserve_event, %{bytes: 268_435_456}, %{kind: "heap"}}

    Engram.Vector.Qdrant.forget_pressure()
    Plugin.execute_collection_metrics()
    refute_receive {:patch, _}
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
end
