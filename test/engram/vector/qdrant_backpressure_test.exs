defmodule Engram.Vector.QdrantBackpressureTest do
  # async: false: the pressure reading is a node-wide cache.
  use ExUnit.Case, async: false

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    Qdrant.forget_pressure()
    on_exit(&Qdrant.forget_pressure/0)
    %{bypass: bypass}
  end

  # The body Qdrant 1.18.2 sends for a strict-mode refusal: CollectionError::
  # StrictMode -> StorageError::BadRequest (HTTP 400, "Bad request: " prefix),
  # message from lib/collection/src/operations/verification/mod.rs.
  @disk_refusal ~S|{"status":{"error":"Bad request: Disk usage is at 87% of total capacity, exceeding the configured limit of 85%. Help: Reduce disk usage (e.g. delete points or drop collections) or raise `max_disk_usage_percent` in strict mode."},"time":0.0001}|
  @memory_refusal ~S|{"status":{"error":"Bad request: Resident memory usage is at 91% of total memory, exceeding the configured limit of 85%. Help: Reduce memory usage (e.g. delete points or free segments) or raise `max_resident_memory_percent` in strict mode."},"time":0.0001}|

  defp respond(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end

  @point %{id: "00000000-0000-0000-0000-000000000001", vector: %{}, payload: %{}}

  describe "strict-mode refusal" do
    test "a disk refusal on upsert is :qdrant_backpressure", %{bypass: bypass} do
      Bypass.expect_once(
        bypass,
        "PUT",
        "/collections/c1/points",
        &respond(&1, 400, @disk_refusal)
      )

      assert {:error, :qdrant_backpressure} = Qdrant.upsert_points("c1", [@point])
    end

    test "a memory refusal on upsert is :qdrant_backpressure", %{bypass: bypass} do
      Bypass.expect_once(
        bypass,
        "PUT",
        "/collections/c1/points",
        &respond(&1, 400, @memory_refusal)
      )

      assert {:error, :qdrant_backpressure} = Qdrant.upsert_points("c1", [@point])
    end

    test "set_payload and update_vectors map it too", %{bypass: bypass} do
      Bypass.expect_once(
        bypass,
        "POST",
        "/collections/c1/points/payload",
        &respond(&1, 400, @disk_refusal)
      )

      Bypass.expect_once(
        bypass,
        "PUT",
        "/collections/c1/points/vectors",
        &respond(&1, 400, @disk_refusal)
      )

      assert {:error, :qdrant_backpressure} = Qdrant.set_payload("c1", [@point.id], %{"a" => 1})
      assert {:error, :qdrant_backpressure} = Qdrant.update_vectors("c1", [@point])
    end

    test "any other 400 stays a plain error", %{bypass: bypass} do
      body = ~s({"status":{"error":"Bad request: Wrong input: Vector dimension error"}})
      Bypass.expect_once(bypass, "PUT", "/collections/c1/points", &respond(&1, 400, body))
      assert {:error, {400, _}} = Qdrant.upsert_points("c1", [@point])
    end
  end

  describe "pressure/0" do
    test "disk from /sys_metrics, heap from /metrics vs the configured limit", %{bypass: bypass} do
      ServiceConfig.put_override(:qdrant_memory_limit_bytes, 2_000_000_000)

      Bypass.stub(bypass, "GET", "/sys_metrics", fn conn ->
        Plug.Conn.send_resp(conn, 200, """
        kubelet_volume_stats_capacity_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} 1e+10
        kubelet_volume_stats_used_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} 8.2e+09
        """)
      end)

      Bypass.stub(bypass, "GET", "/metrics", fn conn ->
        Plug.Conn.send_resp(conn, 200, """
        # HELP memory_resident_bytes Total number of bytes in physically resident data pages mapped
        # TYPE memory_resident_bytes gauge
        memory_resident_bytes 1100000000
        """)
      end)

      assert Qdrant.pressure() == %{disk: 82, heap: 55}
    end

    test "unknown when neither source answers (fail open)", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/sys_metrics", &Plug.Conn.send_resp(&1, 404, ""))

      Bypass.stub(
        bypass,
        "GET",
        "/metrics",
        &Plug.Conn.send_resp(&1, 200, "memory_resident_bytes 5\n")
      )

      # No QDRANT_MEMORY_LIMIT_BYTES: heap is not computed.
      assert Qdrant.pressure() == %{disk: nil, heap: nil}
    end

    test "Qdrant down reads as unknown, never raises", %{bypass: bypass} do
      Bypass.down(bypass)
      assert Qdrant.pressure() == %{disk: nil, heap: nil}
    end

    test "is cached: a second read makes no request", %{bypass: bypass} do
      test_pid = self()

      Bypass.stub(bypass, "GET", "/sys_metrics", fn conn ->
        send(test_pid, :sys_metrics)
        Plug.Conn.send_resp(conn, 404, "")
      end)

      Bypass.stub(bypass, "GET", "/metrics", &Plug.Conn.send_resp(&1, 404, ""))

      Qdrant.pressure()
      Qdrant.pressure()
      assert_receive :sys_metrics
      refute_receive :sys_metrics
    end
  end

  describe "over_pressure?/1" do
    test "80% of either is over; unknown never is" do
      refute Qdrant.over_pressure?(%{disk: nil, heap: nil})
      refute Qdrant.over_pressure?(%{disk: 79, heap: 79})
      assert Qdrant.over_pressure?(%{disk: 80, heap: nil})
      assert Qdrant.over_pressure?(%{disk: nil, heap: 95})
    end
  end
end
