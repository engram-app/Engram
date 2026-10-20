defmodule Engram.Vector.QdrantWaitTest do
  # Worker writes must be APPLIED, not just acknowledged, before the caller
  # stamps the note indexed; and Qdrant must give up on its side before the
  # client does, so a slow request ends as a clean server timeout instead of
  # a client hang-up that leaves the operation running.
  use ExUnit.Case, async: true

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  @col "wait_col"
  @user "00000000-0000-0000-0000-0000000000a1"
  @vault "00000000-0000-0000-0000-0000000000b2"

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    ServiceConfig.put_override(:qdrant_search_timeout, 5_000)
    %{bypass: bypass}
  end

  defp capture(bypass, method, path, resp \\ ~s({"result":{},"status":"ok"})) do
    test_pid = self()

    Bypass.expect_once(bypass, method, path, fn conn ->
      send(test_pid, {:query, path, URI.decode_query(conn.query_string)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, resp)
    end)
  end

  defp assert_wait(path) do
    assert_receive {:query, ^path, query}
    assert query == %{"wait" => "true", "timeout" => "25"}
  end

  test "upsert waits", %{bypass: bypass} do
    capture(bypass, "PUT", "/collections/#{@col}/points")
    assert :ok = Qdrant.upsert_points(@col, [%{id: "p1", vector: [0.1], payload: %{}}])
    assert_wait("/collections/#{@col}/points")
  end

  test "update_vectors waits", %{bypass: bypass} do
    capture(bypass, "PUT", "/collections/#{@col}/points/vectors")
    assert :ok = Qdrant.update_vectors(@col, [%{id: "p1", vector: %{"dense" => [0.1]}}])
    assert_wait("/collections/#{@col}/points/vectors")
  end

  test "set_payload and set_payload_by_filter wait", %{bypass: bypass} do
    path = "/collections/#{@col}/points/payload"
    capture(bypass, "POST", path)
    assert :ok = Qdrant.set_payload(@col, ["p1"], %{"a" => 1})
    assert_wait(path)

    capture(bypass, "POST", path)
    assert :ok = Qdrant.set_payload_by_filter(@col, @user, @vault, "hmac", %{"a" => 1})
    assert_wait(path)
  end

  test "delete_payload_keys waits", %{bypass: bypass} do
    capture(bypass, "POST", "/collections/#{@col}/points/payload/delete")
    assert :ok = Qdrant.delete_payload_keys(@col, ["text"])
    assert_wait("/collections/#{@col}/points/payload/delete")
  end

  test "every point delete waits", %{bypass: bypass} do
    path = "/collections/#{@col}/points/delete"

    for delete <- [
          fn -> Qdrant.delete_points(@col, ["p1"]) end,
          fn -> Qdrant.delete_by_note(@col, @user, @vault, "hmac") end,
          fn -> Qdrant.delete_by_vault(@col, @user, @vault) end,
          fn -> Qdrant.delete_by_user(@col, @user) end
        ] do
      capture(bypass, "POST", path)
      assert :ok = delete.()
      assert_wait(path)
    end
  end

  test "a request-path delete waits with the search budget", %{bypass: bypass} do
    path = "/collections/#{@col}/points/delete"
    capture(bypass, "POST", path)
    assert :ok = Qdrant.delete_by_user(@col, @user, :search)
    assert_receive {:query, ^path, %{"wait" => "true", "timeout" => "4"}}
  end

  test "a search sends a server timeout below the client budget and no wait",
       %{bypass: bypass} do
    path = "/collections/#{@col}/points/query"
    capture(bypass, "POST", path, ~s({"result":{"points":[]},"status":"ok"}))
    assert {:ok, []} = Qdrant.search(@col, [0.1], user_id: @user)
    assert_receive {:query, ^path, query}
    assert query == %{"timeout" => "4"}
  end

  test "the search server timeout follows the client budget and never reaches 0" do
    ServiceConfig.put_override(:qdrant_search_timeout, 30_000)
    assert Qdrant.server_timeout_s(:search) == 29

    ServiceConfig.put_override(:qdrant_search_timeout, 800)
    assert Qdrant.server_timeout_s(:search) == 1

    assert Qdrant.server_timeout_s(:indexing) == 25
  end

  # Qdrant Cloud's strict `max_timeout` (30) 400s any request asking for
  # more, so a configured search budget of 32s or more broke every search
  # (review L5). Clamped; the client budget still waits the full time.
  test "the search server timeout never exceeds the strict max_timeout" do
    max = Engram.Vector.QdrantLayout.desired_strict(:cloud)["max_timeout"]

    for ms <- [31_000, 32_000, 60_000, 600_000] do
      ServiceConfig.put_override(:qdrant_search_timeout, ms)
      assert Qdrant.server_timeout_s(:search) == max
    end
  end

  # `wait=true` past the server `timeout`: HTTP 200 with result.status
  # "wait_timeout" (shard_ops.rs). The op is queued, not applied, so the
  # points may still be invisible; it must not read as success.
  @wait_timeout ~s({"result":{"operation_id":7,"status":"wait_timeout"},"status":"ok"})

  test "every write answers a wait_timeout as :qdrant_wait_timeout, with telemetry",
       %{bypass: bypass} do
    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :qdrant, :wait_timeout]])

    writes = [
      {"PUT", "/points",
       fn -> Qdrant.upsert_points(@col, [%{id: "p1", vector: [0.1], payload: %{}}]) end},
      {"PUT", "/points/vectors",
       fn -> Qdrant.update_vectors(@col, [%{id: "p1", vector: %{}}]) end},
      {"POST", "/points/payload", fn -> Qdrant.set_payload(@col, ["p1"], %{"a" => 1}) end},
      {"POST", "/points/payload",
       fn -> Qdrant.set_payload_by_filter(@col, @user, @vault, "h", %{"a" => 1}) end},
      {"POST", "/points/payload/delete", fn -> Qdrant.delete_payload_keys(@col, ["k"]) end},
      {"POST", "/points/delete", fn -> Qdrant.delete_points(@col, ["p1"]) end},
      {"POST", "/points/delete", fn -> Qdrant.delete_by_note(@col, @user, @vault, "h") end},
      {"POST", "/points/delete", fn -> Qdrant.delete_by_user(@col, @user) end},
      {"POST", "/points/delete", fn -> Qdrant.delete_by_vault(@col, @user, @vault) end}
    ]

    for {method, suffix, write} <- writes do
      capture(bypass, method, "/collections/#{@col}#{suffix}", @wait_timeout)
      assert write.() == {:error, :qdrant_wait_timeout}, suffix
      assert_receive {[:engram, :qdrant, :wait_timeout], ^ref, %{count: 1}, _meta}
    end
  end

  test "a completed or acknowledged write is still :ok", %{bypass: bypass} do
    for status <- ["completed", "acknowledged"] do
      body = ~s({"result":{"operation_id":7,"status":"#{status}"},"status":"ok"})
      capture(bypass, "POST", "/collections/#{@col}/points/delete", body)
      assert :ok = Qdrant.delete_points(@col, ["p1"])
    end
  end
end
