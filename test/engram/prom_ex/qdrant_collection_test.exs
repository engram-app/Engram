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

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    ServiceConfig.put_override(:qdrant_collection_metrics, true)
    :global.unregister_name({Plugin, :collection_poller})

    test_pid = self()
    ref = make_ref()

    :telemetry.attach_many(
      {__MODULE__, ref},
      [@collection_event, @ram_event, @disk_event],
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
          [:engram, :prom_ex, :qdrant, :ram, :bytes]
        ] do
      assert n in names
    end

    assert Enum.flat_map(metrics, & &1.tags) |> Enum.uniq() == [:component]
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
end
