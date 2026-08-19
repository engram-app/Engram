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

  # Paths whose responses Cloudflare is allowed to CACHE, and which therefore
  # must carry a CONSTANT `access-control-allow-origin`.
  #
  # This list has to mirror the Cache Rule in
  # `engram-infra/main/cloudflare/cache.tf`. Keep them in sync: the edge decides
  # what to cache by PATH, so anything it may store must be pinned here by PATH
  # too. Pinning per-ROUTE instead leaves a gap — a request under the prefix
  # that matches no route (a 404) still gets cached-eligible treatment at the
  # edge while carrying an echoed Origin. Verified live before this existed:
  # `GET /.well-known/oauth-bogus` returned `access-control-allow-origin:
  # <echoed>` with `cf-cache-status: BYPASS`, i.e. the rule matched. Only
  # Phoenix's default `private` on the 404 kept a poisoned entry out of the
  # cache, which is incidental protection, not a designed guard.
  @cacheable_prefixes ["/.well-known/oauth-"]
  @cacheable_exact ["/api/openapi", "/openapi"]

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
    |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
    |> put_resp_header(
      "access-control-allow-headers",
      "authorization, content-type, x-vault-id, x-device-id"
    )
    |> put_resp_header("access-control-max-age", "86400")
  end

  # `*` on the edge-cached documents, and this is a CORRECTNESS REQUIREMENT of
  # caching them rather than a loosening. The echo below is right for per-request
  # API traffic and fatal for anything a shared cache stores: the body is
  # identical for every caller, so Cloudflare keeps ONE entry, and whichever
  # client fills it decides the header every other client sees for the next
  # 300s. A browser on app.engram.page then gets a document stamped for
  # mcp.engram.page and the fetch is CORS-blocked.
  #
  # `Vary: Origin` is NOT the fix — Cloudflare honours Vary only for
  # Accept-Encoding, so the entry stays shared.
  #
  # `*` is safe HERE specifically: these are unauthenticated public RFC 8414 /
  # RFC 9728 metadata documents and the OpenAPI spec, all already fetchable by
  # anyone with no Origin at all, and `*` is incompatible with credentialed CORS
  # by construction so it cannot widen access to anything holding a token. Do
  # not extend @cacheable_* to a path that answers differently per user.
  defp resolve_origin(%Plug.Conn{request_path: path} = conn) do
    if cacheable_path?(path), do: "*", else: allowlisted_origin(conn)
  end

  defp cacheable_path?(path) do
    path in @cacheable_exact or Enum.any?(@cacheable_prefixes, &String.starts_with?(path, &1))
  end

  defp allowlisted_origin(conn) do
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
