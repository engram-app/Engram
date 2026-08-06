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

  # Every saas deployment terminates TLS at the edge (Cloudflare -> ALB) and
  # speaks plain HTTP to Bandit, which substitutes the default port for the
  # scheme the SOCKET arrived on whenever the Host header carries no port —
  # 80, while the public scheme is https. Deciding the port against the
  # CANONICAL scheme's default therefore welded `:80` onto every advertised
  # URL, and `https://host:80/oauth/token` does not dial at all: it is a TLS
  # handshake against a plaintext port.
  #
  # Nothing else covers this cell. `config/test.exs` runs the endpoint on plain
  # http, so the canonical scheme matches the socket and the mismatch cannot
  # arise; the per-PR conformance gate gets a loopback stack genuinely dialed
  # on `:4000`, where the port genuinely belongs. Both were green while staging
  # advertised an authorization server no client could reach.
  describe "TLS terminated at the edge" do
    setup do
      prev = Application.get_env(:engram, EngramWeb.Endpoint)
      on_exit(fn -> put_endpoint_config(prev) end)
      :ok
    end

    test "drops the port the proxy supplied for the plaintext hop", %{conn: conn} do
      put_canonical_url(host: "app.engram.page", scheme: "https", port: 443)
      Application.put_env(:engram, :cors_origin, ["https://mcp.engram.page"])

      body =
        %{conn | host: "mcp.engram.page", scheme: :http, port: 80}
        |> get("/.well-known/oauth-protected-resource")
        |> json_response(200)

      assert body["resource"] == "https://mcp.engram.page/api/mcp"
      assert body["authorization_servers"] == ["https://mcp.engram.page"]
    end

    test "the challenge drops it too, so pointer and document agree", %{conn: conn} do
      put_canonical_url(host: "app.engram.page", scheme: "https", port: 443)
      Application.put_env(:engram, :cors_origin, ["https://mcp.engram.page"])

      challenge =
        %{conn | host: "mcp.engram.page", scheme: :http, port: 80}
        |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
        |> get_resp_header("www-authenticate")
        |> hd()

      assert challenge =~
               "https://mcp.engram.page/.well-known/oauth-protected-resource/api/mcp"

      refute challenge =~ ":80"
    end

    test "drops an echoed :443 too, the mirror of the same mistake", %{conn: conn} do
      # A proxy that forwards `Host: host:443` over the plaintext hop. Judging
      # the port by the CONNECTION's scheme alone would keep this one (443 is
      # not http's default) and advertise `https://engram.ax:443` to a client
      # that dialed `https://engram.ax`. Both defaults have to mean "no port".
      put_canonical_url(host: "engram.ax", scheme: "https", port: 443)
      Application.put_env(:engram, :cors_origin, ["https://engram.ax"])

      body =
        %{conn | host: "engram.ax", scheme: :http, port: 443}
        |> get("/.well-known/oauth-protected-resource")
        |> json_response(200)

      assert body["resource"] == "https://engram.ax/api/mcp"
    end

    test "still keeps a port the client really dialed through that edge", %{conn: conn} do
      # The reason #1260 added the port at all: a self-host published on a
      # non-default port sends it in the Host header, the adapter parses it,
      # and dropping it would name an origin the client never dialed.
      put_canonical_url(host: "engram.ax", scheme: "https", port: 443)
      Application.put_env(:engram, :cors_origin, ["https://engram.ax"])

      body =
        %{conn | host: "engram.ax", scheme: :http, port: 8443}
        |> get("/.well-known/oauth-protected-resource")
        |> json_response(200)

      assert body["resource"] == "https://engram.ax:8443/api/mcp"
    end
  end

  # Phoenix caches the canonical URL in ETS at boot, so putting the app env
  # alone does not move `Endpoint.url/0` — the endpoint has to be told.
  defp put_canonical_url(url_opts) do
    :engram
    |> Application.get_env(EngramWeb.Endpoint)
    |> Keyword.put(:url, url_opts)
    |> put_endpoint_config()
  end

  defp put_endpoint_config(config) do
    Application.put_env(:engram, EngramWeb.Endpoint, config)
    EngramWeb.Endpoint.config_change([{EngramWeb.Endpoint, config}], [])
  end
end
