defmodule EngramWeb.Plugs.CORSTest do
  use EngramWeb.ConnCase, async: false

  test "OPTIONS preflight returns 200 with CORS headers" do
    conn =
      build_conn()
      |> put_req_header("origin", "https://app.engram.dev")
      |> options("/api/health")

    assert conn.status == 200
    assert get_resp_header(conn, "access-control-allow-origin") != []
  end

  test "non-OPTIONS requests also receive the CORS origin header" do
    # The plug runs before the router on all requests, not just preflight.
    conn =
      build_conn()
      |> put_req_header("origin", "https://app.engram.dev")
      |> get("/api/health")

    [origin_header] = get_resp_header(conn, "access-control-allow-origin")
    configured_origin = Application.get_env(:engram, :cors_origin, "*")
    assert origin_header == configured_origin
  end

  test "CORS origin header value matches configured origin" do
    # Presence check is not enough — verify the value equals config, not *.
    Application.put_env(:engram, :cors_origin, "https://custom.example.com")
    on_exit(fn -> Application.delete_env(:engram, :cors_origin) end)

    conn =
      build_conn()
      |> put_req_header("origin", "https://custom.example.com")
      |> options("/api/health")

    assert get_resp_header(conn, "access-control-allow-origin") == ["https://custom.example.com"]
  end

  test "CORS origin comes from config, not hardcoded *" do
    # Shape assertion only — behavioral verification is in the test above.
    origin = Application.get_env(:engram, :cors_origin, "*")
    assert is_binary(origin) or is_list(origin)
  end

  test "list config echoes request Origin when in allowlist" do
    Application.put_env(:engram, :cors_origin, [
      "http://engram.ax",
      "app://obsidian.md"
    ])

    on_exit(fn -> Application.delete_env(:engram, :cors_origin) end)

    conn =
      build_conn()
      |> put_req_header("origin", "app://obsidian.md")
      |> options("/api/health")

    assert get_resp_header(conn, "access-control-allow-origin") == ["app://obsidian.md"]
  end

  test "list config falls back to first entry when Origin not in allowlist" do
    Application.put_env(:engram, :cors_origin, [
      "http://engram.ax",
      "app://obsidian.md"
    ])

    on_exit(fn -> Application.delete_env(:engram, :cors_origin) end)

    conn =
      build_conn()
      |> put_req_header("origin", "https://evil.example.com")
      |> options("/api/health")

    assert get_resp_header(conn, "access-control-allow-origin") == ["http://engram.ax"]
  end
end
