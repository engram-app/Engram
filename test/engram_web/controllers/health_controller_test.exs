defmodule EngramWeb.HealthControllerTest do
  use EngramWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  setup tags do
    if tags[:auth] do
      Application.put_env(:engram, :auth_provider, :local)
      on_exit(fn -> Application.put_env(:engram, :auth_provider, :local) end)
    end

    :ok
  end

  test "GET /health returns 200 with status ok", %{conn: conn} do
    conn = get(conn, "/api/health")
    body = json_response(conn, 200)
    assert body["status"] == "ok"
    assert is_binary(body["version"])
  end

  describe "GET /health/deep (ALB readiness — Postgres only)" do
    test "returns 200 with postgres ok when DB is running", %{conn: conn} do
      conn = get(conn, "/api/health/deep")
      body = json_response(conn, 200)

      assert body["status"] == "ok"
      assert body["checks"] == %{"postgres" => "ok"}
    end

    test "does NOT include qdrant or any non-essential dep", %{conn: conn} do
      # Qdrant outages must not pull tasks from the ALB. Search will 500
      # via the search route; ALB readiness stays narrow on Postgres.
      conn = get(conn, "/api/health/deep")
      body = json_response(conn, 200)

      refute Map.has_key?(body["checks"], "qdrant")
      refute Map.has_key?(body["checks"], "redis")
      refute Map.has_key?(body["checks"], "s3")
    end
  end

  describe "GET /health/deep cluster readiness gate (clustered deploys only)" do
    setup do
      on_exit(fn ->
        Application.delete_env(:engram, :dns_cluster_query)
        Application.delete_env(:engram, :cluster_readiness_opts)
      end)
    end

    test "omits the cluster check entirely when not clustered (self-host shape unchanged)", %{
      conn: conn
    } do
      conn = get(conn, "/api/health/deep")
      refute Map.has_key?(json_response(conn, 200)["checks"], "cluster")
    end

    test "503 while other nodes are discoverable but unjoined (boot window)", %{conn: conn} do
      Application.put_env(:engram, :dns_cluster_query, "app.engram.internal")

      Application.put_env(:engram, :cluster_readiness_opts,
        peers: fn -> [] end,
        resolver: fn _ -> ["10.0.0.9"] end,
        self_ip: "10.0.0.7",
        uptime_ms: 1_000,
        grace_ms: 60_000
      )

      conn = get(conn, "/api/health/deep")
      body = json_response(conn, 503)
      assert body["status"] == "degraded"
      assert body["checks"]["cluster"] == "waiting: cluster_unjoined"
    end

    test "200 once a peer is joined", %{conn: conn} do
      Application.put_env(:engram, :dns_cluster_query, "app.engram.internal")

      Application.put_env(:engram, :cluster_readiness_opts,
        peers: fn -> [:"engram@10.0.0.9"] end,
        resolver: fn _ -> ["10.0.0.9"] end
      )

      conn = get(conn, "/api/health/deep")
      assert json_response(conn, 200)["checks"]["cluster"] == "ok"
    end

    test "200 when legitimately alone (first task / scale-to-1)", %{conn: conn} do
      Application.put_env(:engram, :dns_cluster_query, "app.engram.internal")

      Application.put_env(:engram, :cluster_readiness_opts,
        peers: fn -> [] end,
        resolver: fn _ -> [] end
      )

      conn = get(conn, "/api/health/deep")
      assert json_response(conn, 200)["checks"]["cluster"] == "ok: alone"
    end

    test "200 with warning once the boot grace expires — a discovery outage cannot wedge a deploy",
         %{conn: conn} do
      Application.put_env(:engram, :dns_cluster_query, "app.engram.internal")

      Application.put_env(:engram, :cluster_readiness_opts,
        peers: fn -> [] end,
        resolver: fn _ -> ["10.0.0.9"] end,
        self_ip: "10.0.0.7",
        uptime_ms: 120_000,
        grace_ms: 60_000
      )

      conn = get(conn, "/api/health/deep")
      assert json_response(conn, 200)["checks"]["cluster"] == "ok: unjoined_grace_expired"
    end

    test "logs the grace-expired warning only once, then debug — a sustained split must not spam the alert",
         %{conn: conn} do
      Application.put_env(:engram, :dns_cluster_query, "app.engram.internal")

      Application.put_env(:engram, :cluster_readiness_opts,
        peers: fn -> [] end,
        resolver: fn _ -> ["10.0.0.9"] end,
        self_ip: "10.0.0.7",
        uptime_ms: 120_000,
        grace_ms: 60_000
      )

      on_exit(fn ->
        key = {EngramWeb.HealthController, :cluster_grace_expired_logged}
        if :persistent_term.get(key, false), do: :persistent_term.erase(key)
      end)

      first_log = capture_log(fn -> get(conn, "/api/health/deep") end)
      assert first_log =~ "cluster readiness: unjoined past boot grace"

      # Second probe of the same sustained split must not repeat the
      # warning — test.exs pins `logger level: :warning`, so a debug-level
      # re-log is silently dropped rather than needing string matching here.
      second_log = capture_log(fn -> get(conn, "/api/health/deep") end)
      refute second_log =~ "cluster readiness: unjoined past boot grace"
    end
  end

  describe "GET /health/diagnostics (admin-only full dep matrix)" do
    @tag :auth
    test "rejects unauthenticated requests with 401", %{conn: conn} do
      conn = get(conn, "/api/health/diagnostics")
      assert json_response(conn, 401)
    end

    @tag :auth
    test "rejects non-admin members with 403", %{conn: conn} do
      member = insert(:user, role: "member")
      conn = conn |> authenticate(member) |> get("/api/health/diagnostics")
      assert json_response(conn, 403)
    end

    @tag :auth
    test "admin gets 200 with full dep matrix", %{conn: conn} do
      admin = insert(:user, role: "admin")
      conn = conn |> authenticate(admin) |> get("/api/health/diagnostics")
      body = json_response(conn, 200)

      assert is_map(body["checks"])
      # Each dep must appear with a status string ("ok" or "error: ...").
      # Reachability is asserted per-dep elsewhere; here we lock the shape.
      for dep <- ~w(postgres qdrant s3 kms voyage paddle clerk_jwks) do
        assert Map.has_key?(body["checks"], dep), "missing #{dep} in diagnostics matrix"
        assert is_binary(body["checks"][dep]), "#{dep} status must be a string"
      end

      # "verified" in prod (canary enabled, app booted → guard passed).
      # "disabled" in test (config :engram, :boot_canary_enabled, false).
      assert body["boot_canary"] in ["verified", "disabled"]
    end
  end
end
