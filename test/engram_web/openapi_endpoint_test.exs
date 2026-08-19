defmodule EngramWeb.OpenApiEndpointTest do
  use EngramWeb.ConnCase, async: true

  test "GET /api/openapi serves the rendered spec", %{conn: conn} do
    conn = get(conn, "/api/openapi")

    assert %{"openapi" => "3.0.0", "paths" => paths} = json_response(conn, 200)
    assert Map.has_key?(paths, "/api/health")
  end

  test "the spec is edge-cacheable, and not marked private", %{conn: conn} do
    # ~72 KB re-rendered per request, changing only on deploy. `private` is the
    # specific regression to catch: it forbids a SHARED cache (Cloudflare) from
    # storing the response at all, and it is what Phoenix sends by default, so
    # dropping the pipeline plug would silently restore a full origin round trip
    # for every docs page load and codegen run.
    conn = get(conn, "/api/openapi")

    assert ["public, max-age=300"] = get_resp_header(conn, "cache-control")
  end

  test "health checks are NOT cached", %{conn: conn} do
    # Guards the blast radius of the `:openapi` pipeline plug and of any future
    # broad cache rule. A cached health check reports healthy from the edge
    # while the app is down, which is worse than having no health check.
    conn = get(conn, "/api/health")

    refute get_resp_header(conn, "cache-control") == ["public, max-age=300"]
  end
end
