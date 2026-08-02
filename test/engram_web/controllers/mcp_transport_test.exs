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
end
