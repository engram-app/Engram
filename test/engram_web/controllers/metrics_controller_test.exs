defmodule EngramWeb.MetricsControllerTest do
  use EngramWeb.ConnCase, async: false

  @prev_token Application.compile_env(:engram, :metrics_auth_token)

  setup do
    on_exit(fn ->
      Application.put_env(:engram, :metrics_auth_token, @prev_token)
    end)

    :ok
  end

  describe "GET /metrics" do
    test "401 when no auth header and token configured", %{conn: conn} do
      Application.put_env(:engram, :metrics_auth_token, "expected-secret")

      conn = get(conn, "/metrics")
      assert response(conn, 401)
    end

    test "401 when bearer does not match configured token", %{conn: conn} do
      Application.put_env(:engram, :metrics_auth_token, "expected-secret")

      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong-secret")
        |> get("/metrics")

      assert response(conn, 401)
    end

    test "401 when token not configured at all (fail closed)", %{conn: conn} do
      Application.delete_env(:engram, :metrics_auth_token)

      conn =
        conn
        |> put_req_header("authorization", "Bearer anything")
        |> get("/metrics")

      assert response(conn, 401)
    end

    test "200 with text/plain Prom-format body when bearer matches", %{conn: conn} do
      token = "match-this-secret"
      Application.put_env(:engram, :metrics_auth_token, token)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/metrics")

      body = response(conn, 200)

      [content_type | _] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/plain"

      assert byte_size(body) > 0
      assert body =~ ~r/^#|^[a-zA-Z_][a-zA-Z0-9_]*[ {]/m
    end
  end
end
