defmodule EngramWeb.Plugs.McpOriginGuardTest do
  @moduledoc """
  #1259 finding 2, and the one server obligation `2025-11-25` adds that we did
  not already meet: "servers must respond with HTTP 403 Forbidden for invalid
  Origin headers in Streamable HTTP transport".

  The threat is DNS rebinding against a LOCALLY BOUND server: an attacker page
  resolves its own hostname to 127.0.0.1, the browser reaches the Engram the
  user runs on their own machine, and sends `Origin: https://evil.example`.
  SaaS sits behind Cloudflare so the exposure is smaller; `engram.ax` self-host
  is exactly the deployment shape the check is written for.

  The load-bearing subtlety is that a request with NO Origin must be ALLOWED.
  Every real MCP client (Claude Code, Claude Desktop, mcpjam, curl) is a
  non-browser and sends none; only a browser attaches Origin, and a browser is
  the only thing the rebinding attack can drive. Rejecting an absent Origin
  would refuse every legitimate client and defend against nothing.
  """
  use EngramWeb.ConnCase, async: false

  setup do
    # `put_env(.., nil)` is NOT the same as unset: `get_env(.., "*")` then
    # returns nil rather than the default, and every reader of :cors_origin
    # (including Plugs.CORS) has no clause for nil. Restoring with put_env
    # therefore poisoned unrelated suites in the same sync phase — four admin
    # tests that pass alone and on main. Delete the key when it was absent.
    original = Application.fetch_env(:engram, :cors_origin)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:engram, :cors_origin, value)
        :error -> Application.delete_env(:engram, :cors_origin)
      end
    end)

    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, _vault, _} = Engram.Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)

    %{api_key: api_key}
  end

  defp call_mcp(conn, api_key, origin) do
    conn = put_req_header(conn, "authorization", "Bearer #{api_key}")
    conn = if origin, do: put_req_header(conn, "origin", origin), else: conn

    post(conn, "/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
  end

  describe "with an allowlist configured" do
    setup do
      Application.put_env(:engram, :cors_origin, ["https://app.engram.page", "app://obsidian.md"])
      :ok
    end

    test "an off-allowlist Origin is 403", %{conn: conn, api_key: key} do
      resp = call_mcp(conn, key, "https://evil.example")

      assert resp.status == 403
    end

    test "an allowlisted Origin is served", %{conn: conn, api_key: key} do
      resp = call_mcp(conn, key, "https://app.engram.page")

      assert resp.status == 200
    end

    test "a non-browser client sending NO Origin is served", %{conn: conn, api_key: key} do
      # The case that matters: every real MCP client looks like this.
      resp = call_mcp(conn, key, nil)

      assert resp.status == 200
    end

    test "the refusal is a JSON-RPC error, not a bare Plug 403", %{conn: conn, api_key: key} do
      # McpErrorEnvelope rewrites refusals on this pipeline so a client sees
      # JSON-RPC rather than a REST body it cannot parse.
      body = call_mcp(conn, key, "https://evil.example").resp_body

      assert body =~ "jsonrpc"
    end

    test "it refuses BEFORE auth, so a bad Origin with no token is still 403", %{conn: conn} do
      resp =
        conn
        |> put_req_header("origin", "https://evil.example")
        |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      # Not 401: the Origin is rejected on its own terms, and running the guard
      # first keeps an unauthenticated rebinding probe from reaching auth at all.
      assert resp.status == 403
    end
  end

  describe "with cors_origin unset or wildcard" do
    test "any Origin is served, so dev and CI are unaffected", %{conn: conn, api_key: key} do
      Application.put_env(:engram, :cors_origin, "*")

      assert call_mcp(conn, key, "https://anything.example").status == 200
    end

    test "a single configured origin still rejects others", %{conn: conn, api_key: key} do
      Application.put_env(:engram, :cors_origin, "https://app.engram.page")

      assert call_mcp(conn, key, "https://evil.example").status == 403
      assert call_mcp(conn, key, "https://app.engram.page").status == 200
    end
  end

  describe "an unset or nil config" do
    test "nil is treated as unset, not as a crash", %{conn: conn, api_key: key} do
      # Reachable for real: any code path that restores :cors_origin with
      # put_env(.., nil) leaves the key present and nil.
      Application.put_env(:engram, :cors_origin, nil)

      assert call_mcp(conn, key, "https://anything.example").status == 200
    end
  end

  describe "malformed input" do
    setup do
      Application.put_env(:engram, :cors_origin, ["https://app.engram.page"])
      :ok
    end

    test "an invalid-UTF-8 Origin is refused, not crashed", %{conn: conn, api_key: key} do
      assert call_mcp(conn, key, <<0xFF, 0xFE>>).status == 403
    end

    test "an empty Origin is refused", %{conn: conn, api_key: key} do
      assert call_mcp(conn, key, "").status == 403
    end
  end
end
