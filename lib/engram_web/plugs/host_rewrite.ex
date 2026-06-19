defmodule EngramWeb.Plugs.HostRewrite do
  @moduledoc """
  Host-driven path rewrite for the dedicated `api.engram.page` and
  `mcp.engram.page` saas hosts. The same Phoenix endpoint also serves
  selfhost (`engram.ax`) and the canonical `app.engram.page` host without
  any rewrite. Behavior:

    * `api.engram.page` — prefix `/api` if the path doesn't already start
      with `/api`, `/socket`, `/webhooks`, or `/.well-known`. After rewrite,
      reject anything that would have resolved outside those scopes.
    * `mcp.engram.page` — pass `/.well-known/oauth-*` through unmodified;
      otherwise prefix `/api/mcp` if not already prefixed; reject anything
      that would resolve outside `/api/mcp/*` or `/.well-known/oauth-*`.
    * Any other host — passthrough.

  Config-driven via `Application.get_env(:engram, :host_rewrite)`:

      config :engram, :host_rewrite, api_host: "api.engram.page", mcp_host: "mcp.engram.page"

  When unset (default), the plug is a strict no-op — selfhost releases never
  touch the rewrite path.
  """
  import Plug.Conn

  # Allowed top-level scopes that should pass through unmodified on
  # `api.engram.page`. Matched with `under?/2` (exact match OR followed
  # by `/`) so `/api-keys` does NOT match `/api` — `/api-keys` is a known
  # API segment that needs rewriting to `/api/api-keys`.
  @api_allowed_prefixes ~w(/api /socket /webhooks /.well-known)
  # Every top-level segment under `scope "/api", EngramWeb` in router.ex.
  # Missing entries silently 404 in prod — guarded by a regression test.
  @api_top_segments ~w(
    notes folders search vaults attachments oauth mcp auth admin billing
    tasks health user me onboarding api-keys connections tags sync logs
    embed-status openapi
  )

  # Test-only accessor exposing the @api_top_segments allowlist so the
  # router-derived regression test can compare against router.__routes__/0.
  # Underscored name signals "do not call from production code".
  @doc false
  def __api_top_segments__, do: @api_top_segments

  # `init/1` normalizes opts to a keyword list with `:api_host` and
  # `:mcp_host` keys. The endpoint mounts this plug without explicit opts,
  # so `init([])` yields the runtime-read sentinel `:runtime`; `call/2`
  # then looks up `Application.get_env(:engram, :host_rewrite, [])`
  # per-request. Direct unit tests pass an explicit opts list (which
  # always has at least one key here) and short-circuit the runtime read.
  def init([]), do: :runtime
  def init(:runtime), do: :runtime

  def init(opts) when is_list(opts) do
    opts
    |> Keyword.put_new(:api_host, nil)
    |> Keyword.put_new(:mcp_host, nil)
    |> Keyword.put_new(:reject_unknown_hosts, false)
    |> Keyword.put_new(:allowed_extra_hosts, [])
  end

  def call(conn, :runtime) do
    case Application.get_env(:engram, :host_rewrite, []) do
      # Strict no-op when unset — selfhost releases never touch the
      # rewrite path.
      [] -> conn
      opts when is_list(opts) -> call(conn, init(opts))
    end
  end

  def call(conn, opts) when is_list(opts) do
    api_host = opts[:api_host]
    mcp_host = opts[:mcp_host]

    cond do
      api_host && conn.host == api_host -> handle_api_host(conn)
      mcp_host && conn.host == mcp_host -> handle_mcp_host(conn)
      true -> handle_unknown_host(conn, opts)
    end
  end

  # When `:reject_unknown_hosts` is true AND the request host is not on the
  # explicit allowlist, return 410 Gone with a pointer to `api_host`. This
  # guards saas AWS Phoenix from serving the stale bundled SPA on hosts like
  # `app.engram.page` (which after DNS cutover should resolve to Cloudflare
  # Pages, not the ALB). Selfhost never sets this flag — defaults to false.
  # Health probes hit this plug on hosts that are neither api_host nor
  # mcp_host: the ALB target-group HC (`/api/health/deep`, Host = task IP)
  # and the ECS container HC (`curl localhost:4000/api/health`). They MUST
  # pass through on any host — otherwise reject_unknown_hosts=true would 410
  # them, tasks go unhealthy, and the deployment circuit breaker rolls back.
  @health_paths ~w(/api/health /api/health/deep)

  # Same any-host requirement: the Grafana Agent sidecar scrapes the PromEx
  # endpoint as `curl localhost:4000/metrics` (Host = localhost, an unknown
  # host). Without this exemption reject_unknown_hosts=true 410s every scrape
  # → up=0 → no app/BEAM metrics. The route stays bearer-guarded by
  # EngramWeb.Plugs.MetricsAuth, so passing it through here is safe.
  @metrics_path "/metrics"

  defp handle_unknown_host(conn, opts) do
    cond do
      conn.request_path in @health_paths ->
        conn

      conn.request_path == @metrics_path ->
        conn

      opts[:reject_unknown_hosts] && conn.host not in opts[:allowed_extra_hosts] ->
        reject_unknown(conn, opts[:api_host])

      true ->
        conn
    end
  end

  defp reject_unknown(conn, api_host) do
    body =
      Jason.encode!(%{
        error: "gone",
        message: "This host no longer serves the web app. Use #{api_host} for API access.",
        api_host: api_host
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(410, body)
    |> halt()
  end

  defp handle_api_host(conn) do
    path = conn.request_path

    cond do
      path == "/" or path == "" -> reject(conn)
      under_any?(path, @api_allowed_prefixes) -> conn
      not known_api_segment?(path) -> reject(conn)
      true -> rewrite_path(conn, "/api" <> path)
    end
  end

  @mcp_wellknown_prefixes [
    "/.well-known/oauth-protected-resource",
    "/.well-known/oauth-authorization-server"
  ]

  defp handle_mcp_host(conn) do
    path = conn.request_path

    cond do
      Enum.any?(@mcp_wellknown_prefixes, &String.starts_with?(path, &1)) -> conn
      String.starts_with?(path, "/api/mcp") -> conn
      # OAuth 2.1 + DCR endpoints (/oauth/authorize|token|register|revoke). The
      # MCP discovery doc advertises mcp.engram.page/oauth/* as the auth server,
      # so these must reach the backend's top-level /oauth routes unchanged —
      # without this they 404 and no client can pair on the dedicated host.
      String.starts_with?(path, "/oauth") -> conn
      path == "/" or path == "" -> rewrite_path(conn, "/api/mcp/")
      true -> reject(conn)
    end
  end

  defp under_any?(path, prefixes), do: Enum.any?(prefixes, &under?(path, &1))

  # True when `path` equals `prefix` or starts with `prefix <> "/"`.
  # Distinguishes `/api/...` (true) from `/api-keys` (false).
  defp under?(path, prefix),
    do: path == prefix or String.starts_with?(path, prefix <> "/")

  defp known_api_segment?(path) do
    case String.split(path, "/", trim: true) do
      [head | _] -> head in @api_top_segments
      _ -> false
    end
  end

  defp rewrite_path(conn, new_path) do
    new_info = new_path |> String.trim_leading("/") |> String.split("/", trim: true)
    %{conn | request_path: new_path, path_info: new_info}
  end

  defp reject(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, ~s({"error":"not_found"}))
    |> halt()
  end
end
