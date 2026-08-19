defmodule EngramWeb.PublicCacheableHeadersTest do
  @moduledoc """
  The `:public_cacheable` pipeline (router) puts two headers on the public,
  edge-cached documents, and the SECOND one is the non-obvious half.

  `EngramWeb.Plugs.CORS` echoes the request Origin back whenever it is in the
  `:cors_origin` allowlist. That is correct for per-request API traffic and
  fatal for anything a shared cache stores: the response body is identical for
  every caller, so Cloudflare keeps ONE entry, and whichever client fills it
  decides the `access-control-allow-origin` every other client sees for the
  next 300s. A browser on `app.engram.page` then receives a document stamped
  for `mcp.engram.page` and the fetch is CORS-blocked.

  `Vary: Origin` is not a fix — Cloudflare honours `Vary` only for
  `Accept-Encoding` — so the pipeline pins the header to a constant `*`
  instead. These documents are unauthenticated public metadata, so `*` grants
  nothing that was not already public.

  `async: false`: these tests swap `:cors_origin` in application env.
  """
  use EngramWeb.ConnCase, async: false

  @allowlisted "https://mcp.example.test"
  @cacheable_paths [
    "/.well-known/oauth-protected-resource",
    "/.well-known/oauth-authorization-server",
    "/api/openapi"
  ]

  setup do
    prev = Application.get_env(:engram, :cors_origin)

    # A LIST is what makes CORS echo. With the test default (`"*"`) the bug
    # cannot reproduce at all, which is why these tests configure prod's shape
    # rather than trusting the default.
    Application.put_env(:engram, :cors_origin, [
      "https://app.example.test",
      @allowlisted
    ])

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:engram, :cors_origin)
        value -> Application.put_env(:engram, :cors_origin, value)
      end
    end)

    :ok
  end

  describe "edge-cached documents" do
    test "pin access-control-allow-origin to a constant, ignoring the request Origin", %{
      conn: conn
    } do
      for path <- @cacheable_paths do
        resp =
          conn
          |> put_req_header("origin", @allowlisted)
          |> get(path)

        assert get_resp_header(resp, "access-control-allow-origin") == ["*"],
               "#{path} echoed the request Origin into a cacheable response"
      end
    end

    test "are shared-cacheable and never private", %{conn: conn} do
      for path <- @cacheable_paths do
        resp = get(conn, path)

        assert get_resp_header(resp, "cache-control") == ["public, max-age=300"],
               "#{path} is not edge-cacheable"
      end
    end
  end

  describe "paths the edge may cache but no route serves" do
    test "a 404 under the cached prefix still gets a constant origin", %{conn: conn} do
      # The gap this closes. The Cloudflare rule matches by PATH PREFIX
      # (/.well-known/oauth-), the router pins headers per matched ROUTE, and
      # the difference between those two is reachable. Verified against prod
      # before the fix: GET /.well-known/oauth-bogus-does-not-exist returned
      # `access-control-allow-origin: https://mcp.engram.page` (echoed) with
      # `cf-cache-status: BYPASS` — BYPASS meaning the cache rule DID match and
      # the edge declined only because Phoenix's 404 happens to send `private`.
      #
      # That is incidental protection. Give a fallback a `public` cache-control
      # someday and the poisoning is back, via a path nobody thinks of as an
      # endpoint. Pinning in the CORS plug by path removes the gap instead of
      # relying on the 404's headers.
      resp =
        conn
        |> put_req_header("origin", @allowlisted)
        |> get("/.well-known/oauth-bogus-does-not-exist")

      assert resp.status == 404

      assert get_resp_header(resp, "access-control-allow-origin") == ["*"],
             "an unrouted path under the cached prefix echoed the request Origin"
    end
  end

  describe "everything else" do
    test "still echoes an allowlisted Origin", %{conn: conn} do
      # The override must be scoped to the cached documents. If it leaked into
      # the `:api` pipeline it would silently break every browser client that
      # relies on an exact-origin match, so pin the normal behaviour too.
      resp =
        conn
        |> put_req_header("origin", @allowlisted)
        |> get("/api/health")

      assert get_resp_header(resp, "access-control-allow-origin") == [@allowlisted]
    end

    test "health checks are not shared-cacheable", %{conn: conn} do
      # Deliberately stronger than "is not exactly `public, max-age=300`": any
      # `public` directive at all lets the edge serve a cached 200 while the
      # app is down, which is worse than having no health check. Assert the
      # property, not one string.
      cache_control =
        conn
        |> get("/api/health")
        |> get_resp_header("cache-control")
        |> List.first()
        |> Kernel.||("")

      refute cache_control =~ "public",
             "health check is shared-cacheable: #{inspect(cache_control)}"
    end
  end
end
