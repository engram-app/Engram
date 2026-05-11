defmodule EngramWeb.SpaControllerTest do
  use EngramWeb.ConnCase, async: false

  setup do
    # Invalidate cached split so each test gets a fresh file read
    :persistent_term.erase({EngramWeb.SpaController, :split})
    :ok
  end

  test "GET / returns HTML with index.html content", %{conn: conn} do
    conn = get(conn, "/")
    assert response_content_type(conn, :html)
    assert conn.status == 200
    body = response(conn, 200)
    assert body =~ "<!DOCTYPE html>"
    assert body =~ "<div id=\"root\">"
  end

  test "GET /note/some/path returns index.html (SPA fallback)", %{conn: conn} do
    conn = get(conn, "/note/some/path")
    assert conn.status == 200
    assert response(conn, 200) =~ "<!DOCTYPE html>"
  end

  test "GET /share/abc123 returns index.html (SPA fallback)", %{conn: conn} do
    conn = get(conn, "/share/abc123")
    assert conn.status == 200
    assert response(conn, 200) =~ "<!DOCTYPE html>"
  end

  test "GET /share/abc123/folder/note returns index.html (SPA fallback)", %{conn: conn} do
    conn = get(conn, "/share/abc123/folder/note")
    assert conn.status == 200
    assert response(conn, 200) =~ "<!DOCTYPE html>"
  end

  test "GET / injects runtime config script", %{conn: conn} do
    body = conn |> get("/") |> response(200)
    assert body =~ "window.__ENGRAM_CONFIG__="
    assert body =~ ~s("authProvider":)
  end

  test "API routes are NOT caught by SPA fallback", %{conn: conn} do
    conn = get(conn, "/api/health")
    assert json_response(conn, 200)
  end
end
