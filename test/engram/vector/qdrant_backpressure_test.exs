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

  @static_limits %{disk: %{percent: 85, reserve: nil}, heap: %{percent: 85, reserve: nil}}

  defp stub_collection_bytes(bypass, nil) do
    Bypass.stub(
      bypass,
      "GET",
      "/collections/engram_notes/memory",
      &Plug.Conn.send_resp(&1, 404, "")
    )
  end

  defp stub_collection_bytes(bypass, bytes) do
    Bypass.stub(bypass, "GET", "/collections/engram_notes/memory", fn conn ->
      respond(conn, 200, Jason.encode!(%{result: %{total: %{disk_bytes: bytes}}}))
    end)
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

    # Captured from Qdrant 1.19.2 (10.0.20.201, 2026-10-19) with strict
    # limits set to trip: the breakers and the request-shape limits. Every
    # strict-mode refusal is backpressure: a retry re-embeds (and re-pays
    # Voyage) only to be refused again.
    @strict_refusals [
      "Bad request: Max points count limit of 2 reached!",
      "Bad request: Max vector storage size limit of 0.000009536743MB reached!",
      "Bad request: Max payload storage size limit of 0.000009536743MB reached!",
      ~S|Bad request: Limit exceeded 4 > 3 for "upsert limit". Help: Reduce the "upsert limit" parameter to or below 3.|,
      "Bad request: Condition size limit reached (3 > 2). Help: Reduce the size of your condition.",
      "Bad request: Filter condition limit reached (3 > 2). Help: Reduce the amount of conditions of your filter."
    ]

    test "every strict-mode breaker and limit refusal is :qdrant_backpressure", %{bypass: bypass} do
      for message <- @strict_refusals do
        body = Jason.encode!(%{status: %{error: message}, time: 0.0001})
        Bypass.expect_once(bypass, "PUT", "/collections/c1/points", &respond(&1, 400, body))
        assert {:error, :qdrant_backpressure} = Qdrant.upsert_points("c1", [@point]), message
      end
    end

    test "any other 400 stays a plain error", %{bypass: bypass} do
      body = ~s({"status":{"error":"Bad request: Wrong input: Vector dimension error"}})
      Bypass.expect_once(bypass, "PUT", "/collections/c1/points", &respond(&1, 400, body))
      assert {:error, {400, _}} = Qdrant.upsert_points("c1", [@point])
    end
  end

  # Qdrant 1.19 node-wide quota refusals: StorageError::InsufficientStorage
  # -> HTTP 507 (src/actix/helpers.rs), message from
  # lib/shard/src/quota/check.rs `rejected/3` (v1.19.2). The second form is
  # the release-margin hold: usage is back under the limit but not yet
  # `release_margin_percent` below it.
  @quota_disk_refusal ~S|{"status":{"error":"Disk usage is at 95% of total capacity, exceeding the configured limit of 90%. Help: Reduce disk usage (e.g. delete points or drop collections), or raise `max_disk_usage_percent` in the global quota config."},"time":0.0001}|
  @quota_margin_refusal ~S|{"status":{"error":"Resident memory usage is at 87% of total memory. It reached the configured limit of 90% and has to fall below 85% before this node takes writes again. Help: Reduce memory usage (e.g. delete points or drop collections), or raise `max_resident_memory_percent` in the global quota config."},"time":0.0001}|

  describe "quota refusal (Qdrant 1.19+, HTTP 507)" do
    test "upsert, set_payload and update_vectors are :qdrant_backpressure", %{bypass: bypass} do
      Bypass.expect_once(
        bypass,
        "PUT",
        "/collections/c1/points",
        &respond(&1, 507, @quota_disk_refusal)
      )

      Bypass.expect_once(
        bypass,
        "POST",
        "/collections/c1/points/payload",
        &respond(&1, 507, @quota_margin_refusal)
      )

      Bypass.expect_once(
        bypass,
        "PUT",
        "/collections/c1/points/vectors",
        &respond(&1, 507, @quota_disk_refusal)
      )

      assert {:error, :qdrant_backpressure} = Qdrant.upsert_points("c1", [@point])
      assert {:error, :qdrant_backpressure} = Qdrant.set_payload("c1", [@point.id], %{"a" => 1})
      assert {:error, :qdrant_backpressure} = Qdrant.update_vectors("c1", [@point])
    end

    test "a 507 with an unexpected body is still backpressure", %{bypass: bypass} do
      # 507 is only InsufficientStorage; the body wording is not the contract.
      Bypass.expect_once(bypass, "PUT", "/collections/c1/points", &respond(&1, 507, "{}"))
      assert {:error, :qdrant_backpressure} = Qdrant.upsert_points("c1", [@point])
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

      stub_collection_bytes(bypass, 2_000_000_000)

      # Disk reserve max(1 GiB, 0.35 * 2 GB) = 1 GiB of 10 GB -> 89%;
      # heap 2 GB - 256 MiB -> 86%.
      assert Qdrant.pressure() == %{
               disk: 82,
               heap: 55,
               limits: %{
                 disk: %{percent: 89, reserve: 1_073_741_824},
                 heap: %{percent: 86, reserve: 268_435_456}
               }
             }
    end

    test "unknown when neither source answers (fail open)", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/sys_metrics", &Plug.Conn.send_resp(&1, 404, ""))

      Bypass.stub(
        bypass,
        "GET",
        "/metrics",
        &Plug.Conn.send_resp(&1, 200, "memory_resident_bytes 5\n")
      )

      stub_collection_bytes(bypass, nil)

      # No QDRANT_MEMORY_LIMIT_BYTES: heap is not computed.
      assert Qdrant.pressure() == %{disk: nil, heap: nil, limits: @static_limits}
    end

    test "Qdrant down reads as unknown, never raises", %{bypass: bypass} do
      Bypass.down(bypass)
      assert Qdrant.pressure() == %{disk: nil, heap: nil, limits: @static_limits}
    end

    test "is cached: a second read makes no request", %{bypass: bypass} do
      test_pid = self()

      Bypass.stub(bypass, "GET", "/sys_metrics", fn conn ->
        send(test_pid, :sys_metrics)
        Plug.Conn.send_resp(conn, 404, "")
      end)

      Bypass.stub(bypass, "GET", "/metrics", &Plug.Conn.send_resp(&1, 404, ""))
      stub_collection_bytes(bypass, nil)

      Qdrant.pressure()
      Qdrant.pressure()
      assert_receive :sys_metrics
      refute_receive :sys_metrics
    end
  end

  describe "over_pressure?/1" do
    test "pauses 5 points below each strict limit" do
      limits = %{disk: %{percent: 79, reserve: 1}, heap: %{percent: 87, reserve: 1}}
      refute Qdrant.over_pressure?(%{disk: 73, heap: 81, limits: limits})
      assert Qdrant.over_pressure?(%{disk: 74, heap: nil, limits: limits})
      assert Qdrant.over_pressure?(%{disk: nil, heap: 82, limits: limits})
    end

    test "the margin is configurable" do
      ServiceConfig.put_override(:qdrant_preflight_margin_points, 10)
      limits = %{disk: %{percent: 79, reserve: 1}, heap: %{percent: 87, reserve: 1}}
      assert Qdrant.over_pressure?(%{disk: 69, heap: nil, limits: limits})
    end

    test "without limits: static 85 - 5 = 80; unknown never is over" do
      refute Qdrant.over_pressure?(%{disk: nil, heap: nil})
      refute Qdrant.over_pressure?(%{disk: 79, heap: 79})
      assert Qdrant.over_pressure?(%{disk: 80, heap: nil})
      assert Qdrant.over_pressure?(%{disk: nil, heap: 95})
    end
  end
end
