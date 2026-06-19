defmodule EngramWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :engram

  # Wraps the plug pipeline in a rescue that reports any unhandled
  # exception to Sentry before re-raising. No-op when SENTRY_DSN is
  # unset (dev/test/self-host).
  use Sentry.PlugCapture

  socket "/socket", EngramWeb.UserSocket,
    websocket: [
      check_origin: {__MODULE__, :check_origin, []}
    ],
    longpoll: false

  # Origin-allowlist probe — no auth, no channels. Reuses the same
  # check_origin MFA as the main socket so the smoke validates the
  # exact allowlist used by UserSocket. See EngramWeb.OriginProbeSocket
  # moduledoc and engram-infra ops/post-apply-smoke/ws.sh.
  socket "/socket/origin-probe", EngramWeb.OriginProbeSocket,
    websocket: [
      check_origin: {__MODULE__, :check_origin, []}
    ],
    longpoll: false

  @doc false
  # Phoenix.Socket.Transport invokes this MFA with `URI.parse(origin)`, so we must
  # normalize the URI back to a `scheme://host[:port]` string before comparing
  # against the configured allowlist.
  def check_origin(origin) do
    case Application.get_env(:engram, :websocket_check_origin, false) do
      false -> true
      list when is_list(list) -> normalize_origin(origin) in list
      _ -> false
    end
  end

  defp normalize_origin(%URI{scheme: nil}), do: nil

  defp normalize_origin(%URI{scheme: scheme, host: host, port: port}) do
    default = URI.default_port(scheme)
    port_part = if is_nil(port) or port == default, do: "", else: ":#{port}"
    "#{scheme}://#{host}#{port_part}"
  end

  defp normalize_origin(origin) when is_binary(origin), do: origin

  # RequestId runs FIRST so request_id is attached to every response —
  # including 404/410 rejections from HostRewrite — for log correlation.
  plug Plug.RequestId

  # Tidewave MCP (dev only) — runtime introspection of the running app
  # for AI tooling (project_eval, DB queries, logs) at /tidewave/mcp.
  # Mounted BEFORE HostRewrite so the dev endpoint is never subject to
  # saas-only host rejection (e.g. when running `make saas-dev`).
  # `code_reloading?` is true only in :dev and is evaluated at compile
  # time, so the `Tidewave` module (an `only: :dev` dep, absent in
  # prod/test) is never referenced outside dev — same pattern as the
  # `Phoenix.CodeReloader` guard below.
  if code_reloading? do
    plug Tidewave
  end

  # HostRewrite runs BEFORE Plug.Static so saas-only host rejection (410
  # Gone on app.engram.page after the saas-only cutover) covers static
  # assets too — otherwise `app.engram.page/favicon.ico` and
  # `app.engram.page/assets/*.js` would be served by Plug.Static and
  # leak stale bundles past the rewrite contract. The plug itself reads
  # `Application.get_env(:engram, :host_rewrite, [])` at request time
  # (NOT compile time) so the runtime env flag actually takes effect on
  # a saas release and tests can mutate it via `Application.put_env`.
  # When unset (default), the plug is a strict no-op — selfhost releases
  # never touch the rewrite path.
  plug EngramWeb.Plugs.HostRewrite

  # Serve SPA hashed assets at "/assets/*" from priv/static/app/assets.
  # Vite outputs hashed filenames so these can be served with long-lived
  # cache headers (handled by Plug.Static's default).
  plug Plug.Static,
    at: "/assets",
    from: {:engram, "priv/static/app/assets"},
    gzip: not code_reloading?

  # Serve top-level static files (favicon, robots) from priv/static.
  plug Plug.Static,
    at: "/",
    from: :engram,
    gzip: not code_reloading?,
    only: EngramWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :engram
  end

  # `log: false` suppresses Phoenix.Logger's default request log emission,
  # which interpolates conn.method + conn.request_path into the message body
  # (past the metadata-only RedactFilter). EngramWeb.RequestLogger replaces
  # it with a structured equivalent that routes the path through metadata.
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint], log: false

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    body_reader: {EngramWeb.Plugs.CacheRawBody, :read_body, []},
    json_decoder: Phoenix.json_library(),
    length: 11_000_000

  # Sentry context: attaches conn metadata (request_id, method, route,
  # status) to any exception reported by PlugCapture above. Placed after
  # Plug.Parsers so the parsed body would be available — but bodies are
  # explicitly NOT shipped (notes/attachments may contain anything
  # sensitive). Cookies are stripped for the same reason; the default
  # header scrubber already drops auth + cookie.
  plug Sentry.PlugContext,
    body_scrubber: nil,
    cookie_scrubber: nil

  plug Plug.Head
  plug EngramWeb.Plugs.CORS
  plug EngramWeb.Router
end
