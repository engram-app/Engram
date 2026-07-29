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

  test "GET /share/abc123 now serves the SPA as a vault-scoped route", %{conn: conn} do
    # Was a dedicated 404 test pre-Task-7: the whitelist had no /share entry
    # and there was no catch-all, so it 404'd. Task 7 adds /:slug/:id as a
    # generic 2-segment dynamic route for ANY slug, so /share/abc123 is now
    # indistinguishable from /my-vault/<id> at the router level ("share" is
    # just a slug value). No share feature was revived; the frontend/vault
    # lookup decides what "share" resolves to. Deeper (3+ segment) paths
    # still have no matching route and 404, asserted below.
    assert conn |> get("/share/abc123") |> response(200)
  end

  test "GET /share/abc123/folder/note still 404s (no 3-segment SPA route)", %{conn: conn} do
    assert conn |> get("/share/abc123/folder/note") |> response(404)
  end

  test "GET / injects runtime config script", %{conn: conn} do
    body = conn |> get("/") |> response(200)
    assert body =~ "window.__ENGRAM_CONFIG__="
    assert body =~ ~s("authProvider":)
  end

  test "GET / injects billingEnabled flag so the SPA can gate the billing page", %{conn: conn} do
    body = conn |> get("/") |> response(200)
    assert body =~ ~s("billingEnabled":)
  end

  test "GET / injects self-host bootstrap state so auth pages render without a flash",
       %{conn: conn} do
    prev = Application.get_env(:engram, :auth_provider)
    Application.put_env(:engram, :auth_provider, :local)
    on_exit(fn -> Application.put_env(:engram, :auth_provider, prev || :local) end)

    body = conn |> get("/") |> response(200)
    assert body =~ ~s("bootstrap":{)
    assert body =~ ~s("bootstrap_pending":)
    assert body =~ ~s("registration_mode":)
  end

  test "GET / does not inject bootstrap state under Clerk (SaaS)", %{conn: conn} do
    prev = Application.get_env(:engram, :auth_provider)
    Application.put_env(:engram, :auth_provider, :clerk)
    on_exit(fn -> Application.put_env(:engram, :auth_provider, prev || :local) end)

    body = conn |> get("/") |> response(200)
    assert body =~ ~s("bootstrap":null)
  end

  test "GET / injects clerkWaitlistMode=false by default", %{conn: conn} do
    prev = Application.get_env(:engram, :clerk_waitlist_mode)
    Application.delete_env(:engram, :clerk_waitlist_mode)
    on_exit(fn -> Application.put_env(:engram, :clerk_waitlist_mode, prev) end)

    body = conn |> get("/") |> response(200)
    assert body =~ ~s("clerkWaitlistMode":false)
  end

  test "GET / injects clerkWaitlistMode=true when configured", %{conn: conn} do
    prev = Application.get_env(:engram, :clerk_waitlist_mode)
    Application.put_env(:engram, :clerk_waitlist_mode, true)
    on_exit(fn -> Application.put_env(:engram, :clerk_waitlist_mode, prev) end)

    body = conn |> get("/") |> response(200)
    assert body =~ ~s("clerkWaitlistMode":true)
  end

  test "GET /oauth/consent renders SPA (consent UI route)", %{conn: conn} do
    conn = get(conn, "/oauth/consent")
    assert conn.status == 200
    assert response(conn, 200) =~ "<!DOCTYPE html>"
  end

  test "GET /waitlist renders SPA (Clerk waitlist UI route)", %{conn: conn} do
    # /waitlist is reachable from outside the app (Clerk waitlist invitation
    # emails, marketing CTAs, bookmarks). The router uses an explicit SPA
    # whitelist, so /waitlist must be listed or external links 404.
    conn = get(conn, "/waitlist")
    assert conn.status == 200
    assert response(conn, 200) =~ "<!DOCTYPE html>"
    assert response(conn, 200) =~ "<div id=\"root\">"
  end

  test "SPA responses include x-frame-options: DENY (clickjacking guard)", %{conn: conn} do
    # Critical for /oauth/consent — the consent UI must not be embeddable.
    conn = get(conn, "/oauth/consent")
    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "SPA responses include a Content-Security-Policy header", %{conn: conn} do
    # CSP restricts where injected JS can exfiltrate data even if script-src
    # is permissive. Critical for /oauth/consent in particular.
    conn = get(conn, "/oauth/consent")
    [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "default-src 'self'"
    assert csp =~ "frame-ancestors 'none'"
    assert csp =~ "connect-src"
    assert csp =~ "clerk"
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

  describe "vault-scoped SPA routes" do
    test "serves the SPA for a bare vault slug", %{conn: conn} do
      conn = get(conn, "/my-vault")
      assert html_response(conn, 200) =~ "window.__ENGRAM_CONFIG__="
    end

    test "serves the SPA for a vault-scoped note", %{conn: conn} do
      conn = get(conn, "/my-vault/018f2b3c-0000-7000-8000-000000000000")
      assert html_response(conn, 200) =~ "window.__ENGRAM_CONFIG__="
    end
  end

  describe "non-SPA prefixes must not fall through to /:slug (#858)" do
    # Regression guard: without the deny-list these two-segment typos match
    # `get "/:slug/:id"` and return an HTML 200, masking a broken API call.
    test "a typo'd API path 404s instead of serving HTML", %{conn: conn} do
      conn = get(conn, "/api/notez")
      assert response(conn, 404)
      [content_type] = get_resp_header(conn, "content-type")
      refute content_type =~ "text/html"
    end

    test "a typo'd webhooks path 404s", %{conn: conn} do
      assert conn |> get("/webhooks/bogus") |> response(404)
    end

    test "a typo'd well-known path 404s", %{conn: conn} do
      assert conn |> get("/.well-known/bogus") |> response(404)
    end

    test "a typo'd oauth path 404s", %{conn: conn} do
      assert conn |> get("/oauth/bogus") |> response(404)
    end

    test "a missing asset path 404s (fifth prefix: /assets is Plug.Static, not a router scope)",
         %{conn: conn} do
      # Plug.Static only intercepts requests for files that exist; a
      # mistyped/missing asset path falls through to the router and needs
      # its own deny-list entry or it would match /:slug/:id.
      assert conn |> get("/assets/bogus.js") |> response(404)
    end

    test "a missing email asset path 404s and is not HTML (sixth prefix: /email)",
         %{conn: conn} do
      # /email is also Plug.Static-served via static_paths() (lib/engram_web.ex)
      # and referenced from outbound email HTML. A masked HTML 200 there can
      # get cached by a third-party mail proxy, so this asserts content-type
      # too, not just status.
      conn = get(conn, "/email/missing.png")
      assert response(conn, 404)
      [content_type] = get_resp_header(conn, "content-type")
      refute content_type =~ "text/html"
    end

    test "but /oauth/consent still serves the SPA", %{conn: conn} do
      conn = get(conn, "/oauth/consent")
      assert html_response(conn, 200) =~ "window.__ENGRAM_CONFIG__="
    end
  end
end
