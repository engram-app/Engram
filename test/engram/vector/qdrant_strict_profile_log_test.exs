defmodule Engram.Vector.QdrantStrictProfileLogTest do
  # async: false: raises the global Logger level to see an info line.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  # Which strict-mode profile the boot reconcile applied, and why, is in the
  # log: a scheme-less URL once read as self-host with no trace (review L4).
  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    ServiceConfig.put_override(:qdrant_reconcile_config, true)

    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    Bypass.stub(bypass, :any, :any, fn conn ->
      body =
        case conn.request_path do
          "/" -> %{version: "1.17.1"}
          "/collections/c" -> %{result: %{"config" => %{}}}
          _ -> %{result: true}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)

    :ok
  end

  test "logs the profile read from the host" do
    log = capture_log([level: :info], fn -> Qdrant.reconcile_config("c") end)
    assert log =~ "qdrant strict profile self_host (host)"
  end

  test "logs an override as one" do
    ServiceConfig.put_override(:qdrant_strict_profile, :cloud)
    log = capture_log([level: :info], fn -> Qdrant.reconcile_config("c") end)
    assert log =~ "qdrant strict profile cloud (override)"
  end
end
