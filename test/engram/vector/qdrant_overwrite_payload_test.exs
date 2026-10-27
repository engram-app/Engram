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
    # Pre-#590 plaintext and the oldest layout's note_id: the PUT wiped these.
    for k <- ~w(source_path folder tags note_id), do: assert(k in keys)
    assert [%{"has_id" => ["p1", "p2"]}] = del["filter"]["should"]
    refute_received :put_payload
  end

  test "a failing set is returned and the delete is not sent" do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    Bypass.expect_once(bypass, "POST", @path, &Plug.Conn.send_resp(&1, 500, "boom"))

    assert {:error, {500, "boom"}} = Qdrant.overwrite_payload(@col, ["p1"], %{"u" => "x"})
  end

  test "a failing delete is returned, so the caller retries the whole overwrite" do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    Bypass.expect_once(bypass, "POST", @path, fn conn ->
      Plug.Conn.send_resp(conn, 200, ~s({"result":{"status":"completed"},"status":"ok"}))
    end)

    Bypass.expect_once(bypass, "POST", @path <> "/delete", &Plug.Conn.send_resp(&1, 500, "boom"))

    assert {:error, {500, "boom"}} = Qdrant.overwrite_payload(@col, ["p1"], %{"u" => "x"})
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

  test "the delete step is measured as op delete_payload" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :qdrant, :payload_write]])
    assert :ok = Qdrant.overwrite_payload(@col, ["p1", "p2"], %{"u" => "x"})

    assert_receive {[:engram, :qdrant, :payload_write], ^ref, %{ids: 2}, %{op: :set_payload}}
    assert_receive {[:engram, :qdrant, :payload_write], ^ref, %{ids: 2}, %{op: :delete_payload}}
  end

  describe "the caller tag on payload_write" do
    setup do
      %{ref: :telemetry_test.attach_event_handlers(self(), [[:engram, :qdrant, :payload_write]])}
    end

    test "names the call site on both the set and the delete step", %{ref: ref} do
      assert :ok = Qdrant.overwrite_payload(@col, ["p1"], %{"u" => "x"}, caller: :refresh)

      assert_receive {_, ^ref, _, %{op: :set_payload, caller: :refresh}}
      assert_receive {_, ^ref, _, %{op: :delete_payload, caller: :refresh}}
    end

    test "defaults to other, and an unknown caller cannot widen the tag", %{ref: ref} do
      assert :ok = Qdrant.set_payload(@col, ["p1"], %{"u" => "x"})
      assert_receive {_, ^ref, _, %{caller: :other}}

      assert :ok = Qdrant.set_payload(@col, ["p1"], %{"u" => "x"}, caller: :"note/secret.md")
      assert_receive {_, ^ref, _, %{caller: :other}}
    end

    test "every enum value is accepted as is", %{ref: ref} do
      for c <- Qdrant.payload_callers() do
        assert :ok = Qdrant.set_payload(@col, ["p1"], %{"u" => "x"}, caller: c)
        assert_receive {_, ^ref, _, %{caller: ^c}}
      end
    end

    test "the by-filter repath write is tagged repath", %{ref: ref} do
      assert :ok = Qdrant.set_payload_by_filter(@col, 1, 2, "hmac", %{"path_hmac" => "x"})
      assert_receive {_, ^ref, _, %{op: :set_payload, caller: :repath}}
    end

    test "set_payloads carries the caller and defaults to other", %{ref: ref} do
      Qdrant.set_payloads(@col, [{"p1", %{"u" => "x"}}], caller: :dek_rotation)
      assert_receive {_, ^ref, %{ids: 1}, %{op: :set_payload, caller: :dek_rotation}}

      Qdrant.set_payloads(@col, [{"p1", %{"u" => "x"}}])
      assert_receive {_, ^ref, _, %{caller: :other}}
    end

    test "the PromEx distributions carry it" do
      metrics =
        Engram.Test.PromExMetrics.of(Engram.PromEx.Qdrant)
        |> List.wrap()
        |> Enum.flat_map(& &1.metrics)
        |> Enum.filter(&(Enum.at(&1.name, -2) == :payload_write))

      assert length(metrics) == 2
      assert Enum.all?(metrics, &(:caller in &1.tags))
    end
  end
end
