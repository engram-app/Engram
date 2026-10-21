defmodule Engram.Vector.EnsureCollectionAtBootTest do
  # The collection's payload indexes, for the boot's flag state, are ensured
  # at boot rather than on the first index: a deploy that turns the v5 flags
  # on (a dry run never indexes) must not leave search and the reconcile
  # 400ing on the v5 keys under strict mode. A Qdrant outage at boot is
  # logged and retried, never a crashed app.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Engram.Vector.EnsureCollectionAtBoot

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    Application.put_env(:engram, :v5_payload_format, true)

    on_exit(fn ->
      Application.delete_env(:engram, :qdrant_url)
      Application.delete_env(:engram, :v5_payload_format)
    end)

    test_pid = self()

    Bypass.stub(bypass, "PUT", "/collections/:col/index", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:index, Jason.decode!(body)["field_name"]})
      Plug.Conn.send_resp(conn, 200, ~s({"status":"ok"}))
    end)

    %{bypass: bypass}
  end

  test "creates the v5 payload indexes at boot, then stops", %{bypass: bypass} do
    Bypass.stub(bypass, "PUT", "/collections/:col", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)

    pid = start_supervised!({EnsureCollectionAtBoot, retry_ms: 10})
    ref = Process.monitor(pid)

    assert_receive {:index, "u"}
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "a Qdrant outage at boot is logged and retried, not a crash", %{bypass: bypass} do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Bypass.stub(bypass, "PUT", "/collections/:col", fn conn ->
      if Agent.get_and_update(calls, &{&1 + 1, &1 + 1}) == 1 do
        Plug.Conn.send_resp(conn, 503, ~s({"status":"error"}))
      else
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end
    end)

    log =
      capture_log(fn ->
        pid = start_supervised!({EnsureCollectionAtBoot, retry_ms: 10})
        ref = Process.monitor(pid)
        assert_receive {:index, "u"}
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      end)

    assert log =~ "qdrant boot ensure_collection failed"
    assert Agent.get(calls, & &1) == 2
  end
end
