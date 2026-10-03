defmodule Engram.Workers.TelemetryHeartbeatTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Instance
  alias Engram.Workers.TelemetryHeartbeat

  setup do
    prev_billing = Application.get_env(:engram, :billing_enabled)
    prev_opts = Application.get_env(:engram, :telemetry_req_options)
    Application.put_env(:engram, :billing_enabled, false)

    Application.put_env(:engram, :telemetry_req_options,
      plug: {Req.Test, Engram.Telemetry.Heartbeat}
    )

    System.delete_env("DO_NOT_TRACK")
    System.delete_env("ENGRAM_TELEMETRY")

    on_exit(fn ->
      Application.put_env(:engram, :billing_enabled, prev_billing)

      if prev_opts,
        do: Application.put_env(:engram, :telemetry_req_options, prev_opts),
        else: Application.delete_env(:engram, :telemetry_req_options)
    end)

    test_pid = self()

    Req.Test.stub(Engram.Telemetry.Heartbeat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:ping, conn.method, conn.request_path, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 204, "")
    end)

    :ok
  end

  test "sends nothing when the operator has not opted in" do
    assert :ok = perform_job(TelemetryHeartbeat, %{})
    refute_received {:ping, _, _, _}
  end

  test "POSTs the fixed payload to /api/telemetry/ping when opted in" do
    {:ok, _} = Instance.set_telemetry_enabled(true)
    id = Instance.install_id()

    assert :ok = perform_job(TelemetryHeartbeat, %{})

    assert_received {:ping, "POST", "/api/telemetry/ping", body}
    assert Map.keys(body) |> Enum.sort() == ["arch", "id", "os", "runtime", "version"]
    assert body["id"] == id
  end

  test "swallows a 500 from the collector" do
    {:ok, _} = Instance.set_telemetry_enabled(true)
    Req.Test.stub(Engram.Telemetry.Heartbeat, &Plug.Conn.send_resp(&1, 500, "boom"))
    assert :ok = perform_job(TelemetryHeartbeat, %{})
  end

  test "swallows a transport error (air-gapped install)" do
    {:ok, _} = Instance.set_telemetry_enabled(true)
    Req.Test.stub(Engram.Telemetry.Heartbeat, &Req.Test.transport_error(&1, :econnrefused))
    assert :ok = perform_job(TelemetryHeartbeat, %{})
  end
end
