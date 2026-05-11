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

  test "GET /oauth/consent renders SPA (consent UI route)", %{conn: conn} do
    conn = get(conn, "/oauth/consent")
    assert conn.status == 200
    assert response(conn, 200) =~ "<!DOCTYPE html>"
  end

  test "SPA responses include x-frame-options: DENY (clickjacking guard)", %{conn: conn} do
    # Critical for /oauth/consent — the consent UI must not be embeddable.
    conn = get(conn, "/oauth/consent")
    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "GET /api/health still returns JSON (API not shadowed by SPA)", %{conn: conn} do
    conn = get(conn, "/api/health")
    assert json_response(conn, 200)
  end

  describe "SPA does not shadow Phoenix-owned non-SPA routes" do
    # The router uses an explicit SPA whitelist (no /*path catch-all). Any
    # GET to a Phoenix-owned endpoint must hit its controller (or default
    # 404) — never the SPA shell. Regression guard.

    test "GET /oauth/authorize hits OAuthAuthorizeController, not SPA", %{conn: conn} do
      # Missing params → controller renders 400 with client_error body.
      # Crucially: NOT a 200 SPA shell.
      conn = get(conn, "/oauth/authorize")
      refute response(conn, conn.status) =~ "<div id=\"root\">"
      assert conn.status in [302, 400]
    end

    test "GET /api/does-not-exist returns 404, not SPA HTML", %{conn: conn} do
      conn = get(conn, "/api/does-not-exist")
      assert conn.status == 404
      refute response(conn, 404) =~ "<div id=\"root\">"
    end

    test "GET /oauth/does-not-exist returns 404, not SPA HTML", %{conn: conn} do
      conn = get(conn, "/oauth/does-not-exist")
      assert conn.status == 404
      refute response(conn, 404) =~ "<div id=\"root\">"
    end

    test "GET /assets/missing.js returns 404, not SPA HTML", %{conn: conn} do
      # Plug.Static mounts /assets from priv/static/app/assets; a missing
      # file must fall through to Phoenix's default 404, not the SPA shell.
      # Otherwise the browser receives text/html for a <script src=...>
      # request and silently fails with a MIME-type error.
      conn = get(conn, "/assets/this-file-does-not-exist.js")
      assert conn.status == 404
      refute response(conn, 404) =~ "<div id=\"root\">"
    end
  end
end
