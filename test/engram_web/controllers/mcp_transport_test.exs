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

  # A gate plug halts in the pipeline, long before McpController runs — so its
  # refusal went out as the REST body every other API route gets. An MCP client
  # has no idea what to do with that: it is not a JSON-RPC response, so most
  # surface "HTTP 403" and drop the body, which is how a user can hit a wall
  # for hours with the remedy sitting in a field they never see.
  describe "gate refusals on /api/mcp are JSON-RPC shaped" do
    defp mcp_authed(conn, user) do
      user = ensure_external_id(user)
      token = Engram.Accounts.generate_jwt(user, %{"scope" => "mcp"})
      put_req_header(conn, "authorization", "Bearer #{token}")
    end

    test "an onboarding refusal answers a JSON-RPC error with a readable message",
         %{conn: conn} do
      user = insert(:user, onboarding_profile: %{})

      conn = conn |> mcp_authed(user) |> call_tool("list_folders", %{})

      # Status is unchanged: every existing assertion and every client that
      # keys off it still sees a refusal.
      assert conn.status == 403

      body = Jason.decode!(conn.resp_body)
      assert body["jsonrpc"] == "2.0"
      assert is_binary(body["error"]["message"])
      assert body["error"]["message"] =~ "/onboard"
      refute Map.has_key?(body, "missing")
    end

    test "the original REST fields survive under error.data for machine clients",
         %{conn: conn} do
      user = insert(:user, onboarding_profile: %{})

      conn = conn |> mcp_authed(user) |> call_tool("list_folders", %{})

      data = Jason.decode!(conn.resp_body)["error"]["data"]
      assert data["error"] == "onboarding_required"
      assert data["missing"] == ["profile"]
      assert is_binary(data["resume_url"])
    end

    test "the JSON-RPC id from the request is echoed back", %{conn: conn} do
      user = insert(:user, onboarding_profile: %{})

      conn =
        conn
        |> mcp_authed(user)
        |> post("/api/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 4242,
          "method" => "tools/call",
          "params" => %{"name" => "list_folders", "arguments" => %{}}
        })

      assert Jason.decode!(conn.resp_body)["id"] == 4242
    end

    # 401 is the one refusal that must NOT be reshaped. It is the entry point
    # to OAuth discovery (RFC 9728 §5.1) and its bare body plus challenge
    # header is what a spec-following client acts on.
    test "an unauthenticated 401 is left alone", %{conn: conn} do
      conn = post(conn, "/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      refute Map.has_key?(body, "jsonrpc")
      assert [_challenge] = get_resp_header(conn, "www-authenticate")
    end

    # Scoping guard, mirroring the challenge one above. The envelope is a
    # property of the MCP resource; wrapping REST refusals would break every
    # SPA and plugin caller that reads `error` off the top level.
    test "the same refusal on a REST route keeps its REST shape", %{conn: conn} do
      user = insert(:user, onboarding_profile: %{})

      conn = conn |> mcp_authed(user) |> get("/api/notes")

      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "onboarding_required"
      refute Map.has_key?(body, "jsonrpc")
    end
  end
end
