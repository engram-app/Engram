defmodule EngramWeb.Plugs.HostRewriteTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias EngramWeb.Plugs.HostRewrite

  describe "selfhost / unconfigured passthrough" do
    test "with no config, leaves conn untouched regardless of host" do
      conn =
        conn(:get, "/api/notes")
        |> Map.put(:host, "engram.ax")

      assert HostRewrite.call(conn, HostRewrite.init([])) == conn
    end

    test "with config but unmatched host, leaves conn untouched" do
      opts = HostRewrite.init(api_host: "api.engram.page", mcp_host: "mcp.engram.page")

      conn =
        conn(:get, "/api/notes")
        |> Map.put(:host, "engram.ax")

      assert HostRewrite.call(conn, opts) == conn
    end
  end

  describe "api.engram.page" do
    setup do
      opts = HostRewrite.init(api_host: "api.engram.page", mcp_host: "mcp.engram.page")
      {:ok, opts: opts}
    end

    test "prefixes /api on bare path", %{opts: opts} do
      conn =
        conn(:get, "/notes/abc")
        |> Map.put(:host, "api.engram.page")
        |> HostRewrite.call(opts)

      assert conn.request_path == "/api/notes/abc"
      assert conn.path_info == ["api", "notes", "abc"]
      refute conn.halted
    end

    test "passes through paths already prefixed /api", %{opts: opts} do
      conn =
        conn(:get, "/api/notes/abc")
        |> Map.put(:host, "api.engram.page")
        |> HostRewrite.call(opts)

      assert conn.request_path == "/api/notes/abc"
      refute conn.halted
    end

    test "passes through /socket, /webhooks, /.well-known", %{opts: opts} do
      for path <- ["/socket/websocket", "/webhooks/paddle", "/.well-known/oauth-authorization-server"] do
        conn =
          conn(:get, path)
          |> Map.put(:host, "api.engram.page")
          |> HostRewrite.call(opts)

        assert conn.request_path == path
        refute conn.halted, "#{path} should not be halted"
      end
    end

    test "rejects paths under SPA root with 404", %{opts: opts} do
      conn =
        conn(:get, "/login")
        |> Map.put(:host, "api.engram.page")
        |> HostRewrite.call(opts)

      assert conn.halted
      assert conn.status == 404
    end

    # Regression: every top-level segment under `scope "/api"` in router.ex
    # must be in @api_top_segments — missing entries = silent 404 in prod.
    test "rewrites all router-known /api top segments", %{opts: opts} do
      segments = ~w(
        notes folders search vaults attachments oauth mcp auth admin billing
        tasks health user me onboarding api-keys connections tags sync logs
        embed-status
      )

      for seg <- segments do
        conn =
          conn(:get, "/" <> seg)
          |> Map.put(:host, "api.engram.page")
          |> HostRewrite.call(opts)

        refute conn.halted, "/#{seg} on api.engram.page should be rewritten, not rejected"
        assert conn.request_path == "/api/" <> seg
      end
    end
  end

  describe "mcp.engram.page" do
    setup do
      opts = HostRewrite.init(api_host: "api.engram.page", mcp_host: "mcp.engram.page")
      {:ok, opts: opts}
    end

    test "passes /.well-known/oauth-* through unchanged", %{opts: opts} do
      for path <- ["/.well-known/oauth-protected-resource",
                   "/.well-known/oauth-protected-resource/api/mcp",
                   "/.well-known/oauth-authorization-server"] do
        conn =
          conn(:get, path)
          |> Map.put(:host, "mcp.engram.page")
          |> HostRewrite.call(opts)

        assert conn.request_path == path
        refute conn.halted, "#{path} should not be halted"
      end
    end

    test "prefixes /api/mcp on bare paths", %{opts: opts} do
      conn =
        conn(:post, "/")
        |> Map.put(:host, "mcp.engram.page")
        |> HostRewrite.call(opts)

      assert conn.request_path == "/api/mcp/"
      refute conn.halted
    end

    test "passes through paths already prefixed /api/mcp", %{opts: opts} do
      conn =
        conn(:post, "/api/mcp/foo")
        |> Map.put(:host, "mcp.engram.page")
        |> HostRewrite.call(opts)

      assert conn.request_path == "/api/mcp/foo"
      refute conn.halted
    end

    test "rejects anything else with 404", %{opts: opts} do
      conn =
        conn(:get, "/notes")
        |> Map.put(:host, "mcp.engram.page")
        |> HostRewrite.call(opts)

      assert conn.halted
      assert conn.status == 404
    end
  end
end
