defmodule EngramWeb.OpenApiEndpointTest do
  use EngramWeb.ConnCase, async: true

  test "GET /api/openapi serves the rendered spec", %{conn: conn} do
    conn = get(conn, "/api/openapi")

    assert %{"openapi" => "3.0.0", "paths" => paths} = json_response(conn, 200)
    assert Map.has_key?(paths, "/api/health")
  end
end
