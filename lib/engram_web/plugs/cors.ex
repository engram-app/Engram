defmodule EngramWeb.Plugs.CORS do
  @moduledoc """
  CORS plug — auth is via Bearer token, not cookies, so allowlist is permissive
  on origin but echoes the request Origin when it matches so non-browser clients
  (Obsidian Electron via fetch) get an exact match.

  Config `:cors_origin` accepts:
    * `"*"` — allow any (default for dev/CI when PHX_HOST unset)
    * `"https://x"` — single origin
    * `["https://x", "app://obsidian.md"]` — allowlist; request Origin echoed if in list, else first
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = put_cors_headers(conn)

    if conn.method == "OPTIONS" do
      conn
      |> send_resp(200, "")
      |> halt()
    else
      conn
    end
  end

  defp put_cors_headers(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", resolve_origin(conn))
    |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "authorization, content-type, x-vault-id")
    |> put_resp_header("access-control-max-age", "86400")
  end

  defp resolve_origin(conn) do
    case Application.get_env(:engram, :cors_origin, "*") do
      "*" ->
        "*"

      origin when is_binary(origin) ->
        origin

      [first | _] = allowlist when is_list(allowlist) ->
        request_origin = get_req_header(conn, "origin") |> List.first()
        if request_origin && request_origin in allowlist, do: request_origin, else: first
    end
  end
end
