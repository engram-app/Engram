defmodule Engram.Vector.QdrantOverwritePayloadTest do
  # `PUT /points/payload` (Qdrant's overwrite) went from ~10 ms to ~3 s p95
  # in prod while `POST /points/payload` stayed ~12 ms. `overwrite_payload/3`
  # therefore never sends the PUT: it merges the new payload and deletes the
  # note-level keys the new payload leaves out, which is the same end state.
  use ExUnit.Case, async: true

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  @col "overwrite_col"
  @path "/collections/#{@col}/points/payload"

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    test = self()

    Bypass.stub(bypass, "PUT", @path, fn conn ->
      send(test, :put_payload)
      Plug.Conn.send_resp(conn, 500, "slow path must not be used")
    end)

    for path <- [@path, @path <> "/delete"] do
      Bypass.stub(bypass, "POST", path, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:write, path, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result":{"status":"completed"},"status":"ok"}))
      end)
    end

    :ok
  end

  test "overwrite_payload merges the new payload and deletes only the absent note keys" do
    assert :ok = Qdrant.overwrite_payload(@col, ["p1", "p2"], %{"u" => "x", "v" => "y"})

    assert_receive {:write, @path, %{"payload" => %{"u" => "x", "v" => "y"}} = set}
    assert [%{"has_id" => ["p1", "p2"]}] = set["filter"]["should"]

    delete_path = @path <> "/delete"
    assert_receive {:write, ^delete_path, %{"keys" => keys} = del}
    refute "u" in keys
    refute "v" in keys
    assert "g" in keys and "path_hmac" in keys
    assert [%{"has_id" => ["p1", "p2"]}] = del["filter"]["should"]
    refute_received :put_payload
  end

  test "an empty id list is a no-op" do
    assert :ok = Qdrant.overwrite_payload(@col, [], %{"u" => "x"})
    refute_received {:write, _, _}
  end

  test "every payload write reports its id count and size" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :qdrant, :payload_write]])
    assert :ok = Qdrant.set_payload(@col, ["p1", "p2", "p3"], %{"u" => "x"})

    assert_receive {[:engram, :qdrant, :payload_write], ^ref, %{ids: 3, bytes: bytes}, _meta}
    assert bytes > 0
  end
end
