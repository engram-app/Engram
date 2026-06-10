defmodule EngramWeb.Plugs.HostRewriteTest do
  use ExUnit.Case, async: true
  import Plug.Test

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

  describe "reject_unknown_hosts" do
    test "with reject_unknown_hosts=false (default), unknown host passes through" do
      opts = HostRewrite.init(api_host: "api.engram.page", mcp_host: "mcp.engram.page")
      conn = conn(:get, "/anything") |> Map.put(:host, "app.engram.page")
      out = HostRewrite.call(conn, opts)

      assert out == conn
      refute out.halted
    end

    test "with reject_unknown_hosts=true, unknown host returns 410 Gone" do
      opts =
        HostRewrite.init(
          api_host: "api.engram.page",
          mcp_host: "mcp.engram.page",
          reject_unknown_hosts: true
        )

      conn = conn(:get, "/anything") |> Map.put(:host, "app.engram.page")
      out = HostRewrite.call(conn, opts)

      assert out.halted
      assert out.status == 410
      body = Jason.decode!(out.resp_body)
      assert body["error"] == "gone"
      assert body["api_host"] == "api.engram.page"
      assert body["message"] =~ "api.engram.page"
    end

    test "with reject_unknown_hosts=true, api_host still rewrites normally" do
      opts =
        HostRewrite.init(
          api_host: "api.engram.page",
          mcp_host: "mcp.engram.page",
          reject_unknown_hosts: true
        )

      conn = conn(:get, "/notes") |> Map.put(:host, "api.engram.page")
      out = HostRewrite.call(conn, opts)

      assert out.request_path == "/api/notes"
      refute out.halted
    end

    test "with reject_unknown_hosts=true and allowed_extra_hosts, listed host passes through" do
      opts =
        HostRewrite.init(
          api_host: "api.engram.page",
          mcp_host: "mcp.engram.page",
          reject_unknown_hosts: true,
          allowed_extra_hosts: ["health.internal", "alb-probe.local"]
        )

      conn = conn(:get, "/health") |> Map.put(:host, "health.internal")
      out = HostRewrite.call(conn, opts)

      refute out.halted
      assert out == conn
    end

    test "with reject_unknown_hosts=true, selfhost-style empty config remains passthrough" do
      # This proves the no-op contract: passing [] (selfhost) ignores the
      # reject_unknown_hosts setting because api_host is nil → dispatch skips
      # the rejection branch.
      opts = HostRewrite.init([])
      conn = conn(:get, "/anything") |> Map.put(:host, "engram.ax")
      out = HostRewrite.call(conn, opts)

      assert out == conn
      refute out.halted
    end
  end

  describe "router/@api_top_segments coherence" do
    test "@api_top_segments covers every router-registered /api top segment" do
      # Walk the router and confirm every distinct /api/<seg> top-level
      # segment is present in @api_top_segments. A missing entry would
      # silently 404 on api.engram.page in prod — this test fails loudly
      # the moment a new /api scope is added without updating the plug.
      router_segments =
        EngramWeb.Router.__routes__()
        |> Enum.filter(&String.starts_with?(&1.path, "/api/"))
        |> Enum.map(&(&1.path |> String.split("/", trim: true) |> Enum.at(1)))
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      plug_segments = MapSet.new(HostRewrite.__api_top_segments__())

      missing = MapSet.difference(router_segments, plug_segments)

      assert MapSet.size(missing) == 0,
             "Router has /api routes for segments [#{Enum.join(Enum.to_list(missing), ", ")}] but " <>
               "plug @api_top_segments doesn't list them — silent 404 in prod"
    end
  end
end
