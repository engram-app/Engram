defmodule EngramWeb.WellKnownHostTest do
  # async: false — these mutate the global :cors_origin app env.
  use EngramWeb.ConnCase, async: false

  setup do
    prev = Application.get_env(:engram, :cors_origin)
    prev_rewrite = Application.get_env(:engram, :host_rewrite)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:engram, :cors_origin, prev),
        else: Application.delete_env(:engram, :cors_origin)

      if prev_rewrite,
        do: Application.put_env(:engram, :host_rewrite, prev_rewrite),
        else: Application.delete_env(:engram, :host_rewrite)
    end)

    :ok
  end

  describe "multi-domain host derivation" do
    test "advertises the dialed host when it is an allowlisted origin", %{conn: conn} do
      Application.put_env(:engram, :cors_origin, [
        "https://app.engram.page",
        "http://app.engram.page"
      ])

      body =
        %{conn | host: "app.engram.page"}
        |> get("/.well-known/oauth-protected-resource")
        |> json_response(200)

      # app.engram.page is allowlisted but NOT the mcp_host → path form.
      assert body["resource"] == "http://app.engram.page/api/mcp"
      assert body["authorization_servers"] == ["http://app.engram.page"]
    end

    test "issuer reflects the dialed allowlisted host", %{conn: conn} do
      Application.put_env(:engram, :cors_origin, ["http://app.engram.page"])

      body =
        %{conn | host: "app.engram.page"}
        |> get("/.well-known/oauth-authorization-server")
        |> json_response(200)

      assert body["issuer"] == "http://app.engram.page"
      assert body["authorization_endpoint"] == "http://app.engram.page/oauth/authorize"
    end

    test "falls back to canonical for a non-allowlisted host (no Host reflection)", %{conn: conn} do
      Application.put_env(:engram, :cors_origin, ["http://app.engram.page"])

      body =
        %{conn | host: "evil.example.com"}
        |> get("/.well-known/oauth-protected-resource")
        |> json_response(200)

      refute body["resource"] =~ "evil.example.com"
      assert String.ends_with?(body["resource"], "/api/mcp")
    end

    test "advertises the BARE host as the resource on the saas mcp_host (Engram#634)", %{
      conn: conn
    } do
      # On the dedicated saas MCP host, HostRewrite serves MCP at the bare root,
      # so the canonical resource is the bare host (no /api/mcp path). Strict
      # clients (Claude Code CLI) paste the bare host and self-check it.
      Application.put_env(:engram, :cors_origin, ["http://mcp.engram.page"])
      Application.put_env(:engram, :host_rewrite, mcp_host: "mcp.engram.page")

      body =
        %{conn | host: "mcp.engram.page"}
        |> get("/.well-known/oauth-protected-resource")
        |> json_response(200)

      assert body["resource"] == "http://mcp.engram.page"
      refute String.ends_with?(body["resource"], "/api/mcp")
      assert body["authorization_servers"] == ["http://mcp.engram.page"]
    end
  end

  # `conn.host` carries no port, so reflecting the dialed host as
  # "#{scheme}://#{conn.host}" silently drops it. Invisible on 80/443 — and
  # wrong everywhere else. A self-host on `http://engram.ax:8080` advertised
  # `http://engram.ax/api/mcp`, which a strict client self-checks against the
  # URL it dialed and aborts on. Same failure class as the RFC 9728 §3.1 and
  # §5.1 gaps: the server misstating where it lives.
  #
  # It also makes any port-mapped deployment untestable end to end, which is
  # why the CI stack could never have caught a URL-derivation bug.
  describe "non-default ports" do
    test "keeps a non-default port when reflecting the dialed host", %{conn: conn} do
      Application.put_env(:engram, :cors_origin, ["http://engram.ax", "https://engram.ax"])

      body =
        %{conn | host: "engram.ax", port: 8080}
        |> get("/.well-known/oauth-protected-resource")
        |> json_response(200)

      assert body["resource"] == "http://engram.ax:8080/api/mcp"
      assert body["authorization_servers"] == ["http://engram.ax:8080"]
    end

    test "omits the port when it is the scheme default", %{conn: conn} do
      Application.put_env(:engram, :cors_origin, ["http://engram.ax"])

      body =
        %{conn | host: "engram.ax", port: 80}
        |> get("/.well-known/oauth-protected-resource")
        |> json_response(200)

      # 80 is implicit for http — emitting it would itself be a mismatch
      # against what the client dialed.
      assert body["resource"] == "http://engram.ax/api/mcp"
    end

    test "the metadata pointer carries the port too", %{conn: conn} do
      # The challenge and the document must agree; a pointer that drops the
      # port resolves to a different origin than the one it describes.
      Application.put_env(:engram, :cors_origin, ["http://engram.ax"])

      challenge =
        %{conn | host: "engram.ax", port: 8080}
        |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
        |> get_resp_header("www-authenticate")
        |> hd()

      assert challenge =~ "http://engram.ax:8080/.well-known/oauth-protected-resource/api/mcp"
    end
  end
end
