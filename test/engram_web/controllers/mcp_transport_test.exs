defmodule EngramWeb.McpTransportTest do
  use EngramWeb.ConnCase, async: true

  # The MCP endpoint is POST-only JSON-RPC. Streamable-HTTP clients open a
  # GET on the endpoint for a server→client SSE stream (and DELETE to end a
  # session). We offer neither, so the spec-correct answer is 405 + Allow —
  # not a 404, which clients treat as a missing endpoint and abort.
  describe "unsupported transport methods on /api/mcp" do
    test "GET returns 405 with Allow: POST (no auth required)", %{conn: conn} do
      conn = get(conn, "/api/mcp")
      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
    end

    test "DELETE returns 405 with Allow: POST (no auth required)", %{conn: conn} do
      conn = delete(conn, "/api/mcp")
      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
    end

    # Regression. The two tests above pass with a bare test conn, which sends no
    # Accept header — so they never exercised the header a REAL client sends.
    # A Streamable-HTTP client opens the server→client stream with
    # `Accept: text/event-stream`, and while these routes piped through `:api`
    # (`plug :accepts, ["json"]`) that produced a 406 before this controller ran.
    # The 405 was therefore unreachable for exactly the clients it exists for.
    # Observed 2026-08-01: Cursor fell back to the legacy HTTP+SSE transport and
    # aborted on "Non-200 status code (406)".
    test "GET with Accept: text/event-stream still returns 405, not 406", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "text/event-stream")
        |> get("/api/mcp")

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
    end

    test "DELETE with Accept: text/event-stream still returns 405, not 406", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "text/event-stream")
        |> delete("/api/mcp")

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
    end

    # The spec-conformant Accept for the stream-open GET lists both types. It
    # worked before (json satisfies `:accepts`) and must keep working — the fix
    # widens what is tolerated, it does not move the answer.
    test "GET with the spec's dual Accept returns 405", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json, text/event-stream")
        |> get("/api/mcp")

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
    end
  end

  # MCP (2025-06-18 onward) makes the server an OAuth 2.1 resource server: an
  # unauthenticated call MUST answer 401 with `WWW-Authenticate` carrying a
  # `resource_metadata` pointer (RFC 9728 §5.1). It is how a client learns
  # WHERE to authenticate. We sent a bare `{"error":"unauthorized"}`, so a
  # client following the spec literally had nothing to go on; only clients that
  # guess the well-known path convention ever connected.
  #
  # Invisible to the MCPJam runner — it guesses, passes the step, and its own
  # step text calls this something servers "often" provide. A compatibility
  # tester grades whether IT can connect, not whether we are compliant. Hence
  # a local test.
  describe "unauthenticated POST /api/mcp (RFC 9728 §5.1 challenge)" do
    test "401 carries WWW-Authenticate with a resource_metadata pointer", %{conn: conn} do
      conn = post(conn, "/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      assert conn.status == 401
      assert [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ ~r/^Bearer /
      assert challenge =~ ~s(resource_metadata=")
    end

    test "the advertised resource_metadata URL actually resolves", %{conn: conn} do
      challenge =
        conn
        |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
        |> get_resp_header("www-authenticate")
        |> hd()

      [_, url] = Regex.run(~r/resource_metadata="([^"]+)"/, challenge)

      # A pointer to a 404 is worse than no pointer: the client stops rather
      # than falling back. Follow it for real.
      body = json_response(get(conn, URI.parse(url).path), 200)
      assert is_binary(body["resource"])
      assert body["authorization_servers"] != []
    end

    # Scoping guard. `Plugs.Auth` is shared by six pipelines — the vault REST
    # scope, admin, invites. Attaching the challenge there would advertise MCP
    # resource metadata on every `/api/notes` 401, pointing SPA and plugin
    # clients at an OAuth flow that is not theirs.
    test "a non-MCP API 401 does NOT carry the MCP challenge", %{conn: conn} do
      conn = get(conn, "/api/notes")

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == []
    end
  end
end
