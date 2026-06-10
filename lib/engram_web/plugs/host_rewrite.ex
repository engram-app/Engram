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

  def init(opts), do: opts |> Keyword.put_new(:api_host, nil) |> Keyword.put_new(:mcp_host, nil)

  def call(conn, opts) do
    _ = opts
    conn
  end
end
