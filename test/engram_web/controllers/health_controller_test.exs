defmodule EngramWeb.HealthControllerTest do
  use EngramWeb.ConnCase, async: false

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
      for dep <- ~w(postgres qdrant redis s3 kms voyage paddle clerk_jwks) do
        assert Map.has_key?(body["checks"], dep), "missing #{dep} in diagnostics matrix"
        assert is_binary(body["checks"][dep]), "#{dep} status must be a string"
      end

      # "verified" in prod (canary enabled, app booted → guard passed).
      # "disabled" in test (config :engram, :boot_canary_enabled, false).
      assert body["boot_canary"] in ["verified", "disabled"]
    end
  end
end
