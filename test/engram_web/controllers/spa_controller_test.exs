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

  test "GET /share/abc123 404s now that vault routes are prefixed", %{conn: conn} do
    # History: pre-Task-7 this 404'd (no /share entry, no catch-all); Task 7's
    # generic `/:slug/:id` made it a 200 because "share" was indistinguishable
    # from a vault slug at the router level. Moving vault routes under `/v/`
    # removes the root wildcard entirely, so it 404s again -- and this time
    # nothing at the root can ever be mistaken for a vault.
    assert conn |> get("/share/abc123") |> response(404)
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

  test "GET / no longer injects clerkWaitlistMode" do
    # The waitlist flow is gone: sign-up is open. A stale key here would let
    # the SPA keep branching on a flag nothing sets.
    conn = build_conn() |> get("/")
    refute response(conn, 200) =~ "clerkWaitlistMode"
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
      conn = get(conn, "/v/my-vault")
      assert html_response(conn, 200) =~ "window.__ENGRAM_CONFIG__="
    end

    test "serves the SPA for a vault-scoped note", %{conn: conn} do
      conn = get(conn, "/v/my-vault/018f2b3c-0000-7000-8000-000000000000")
      assert html_response(conn, 200) =~ "window.__ENGRAM_CONFIG__="
    end

    # The parity test reads the ROUTE TABLE via route_info/4, which never runs
    # `pipeline :spa` and never invokes the controller -- so it cannot see
    # status, content-type, or a halting plug. These drive the full endpoint
    # for the routes this change added, which otherwise had no request-level
    # coverage at all.
    test "serves the SPA for the bare vault prefix", %{conn: conn} do
      conn = get(conn, "/v")
      assert html_response(conn, 200) =~ "window.__ENGRAM_CONFIG__="
    end

    # These two used to assert a 200 shell for `/v/:slug/wiki/*`. That route is
    # DELETED: an unresolved wikilink now creates the note on click instead of
    # routing to a "doesn't exist yet" interstitial, and `wikiHref` emits no
    # `/wiki/` URL at all. Kept, inverted, because a deleted route is exactly
    # what a route manifest cannot catch on its own -- both shapes also sit in
    # `spa-routes.json`'s `mustNotResolve`.
    test "a wikilink deep link 404s -- that route is gone", %{conn: conn} do
      conn = get(conn, "/v/my-vault/wiki/Some%20Note")
      assert conn.status == 404
    end

    test "a wikilink deep link with a slash in the target 404s too", %{conn: conn} do
      conn = get(conn, "/v/my-vault/wiki/Folder/My%20Note")
      assert conn.status == 404
    end

    test "an over-deep vault path 404s rather than serving a soft-404 shell", %{conn: conn} do
      # A greedy `get "/v/*path"` made this a 200 shell that renders an in-app
      # 404 -- healthy to an uptime monitor, indexable as a soft-404. The
      # bounded routes make it a real 404.
      conn = get(conn, "/v/my-vault/some-id/extra")
      assert conn.status == 404
      [ct] = get_resp_header(conn, "content-type")
      refute ct =~ "text/html", "over-deep vault path served an HTML body"
      refute conn.resp_body =~ "window.__ENGRAM_CONFIG__="
    end
  end

  describe "non-SPA prefixes 404 rather than serving the SPA (#858)" do
    # Regression guard. Historically these two-segment typos matched the root
    # `get "/:slug/:id"` and returned an HTML 200, masking a broken API call;
    # a hand-maintained deny-list suppressed that. Vault routes now live under
    # /v/, so there is no root wildcard to fall into and no deny-list.
    # Every case asserts BOTH status and content-type: a status-only check
    # would not catch a regression where not_found/2 started returning
    # text/html with a 404 status, which is exactly the "masked as success"
    # failure mode this guard exists to prevent.
    test "a typo'd API path 404s instead of serving HTML", %{conn: conn} do
      conn |> get("/api/notez") |> assert_not_found_not_html()
    end

    test "a typo'd webhooks path 404s", %{conn: conn} do
      conn |> get("/webhooks/bogus") |> assert_not_found_not_html()
    end

    test "a typo'd well-known path 404s", %{conn: conn} do
      conn |> get("/.well-known/bogus") |> assert_not_found_not_html()
    end

    test "a typo'd oauth path 404s", %{conn: conn} do
      conn |> get("/oauth/bogus") |> assert_not_found_not_html()
    end

    test "a missing asset path 404s (fifth prefix: /assets is Plug.Static, not a router scope)",
         %{conn: conn} do
      # Plug.Static only intercepts requests for files that exist; a
      # mistyped/missing asset path falls through to the router and needs
      # its own deny-list entry or it would match /:slug/:id.
      conn |> get("/assets/bogus.js") |> assert_not_found_not_html()
    end

    test "a missing email asset path 404s and is not HTML (sixth prefix: /email)",
         %{conn: conn} do
      # /email is also Plug.Static-served via static_paths() (lib/engram_web.ex)
      # and referenced from outbound email HTML. A masked HTML 200 there can
      # get cached by a third-party mail proxy, so content-type matters even
      # more here than for /assets.
      conn |> get("/email/missing.png") |> assert_not_found_not_html()
    end

    test "a bare /socket path 404s (seventh prefix: socket dispatch only claims /socket/websocket)",
         %{conn: conn} do
      conn |> get("/socket") |> assert_not_found_not_html()
    end

    test "a typo'd /socket path 404s", %{conn: conn} do
      conn |> get("/socket/bogus") |> assert_not_found_not_html()
    end

    test "but /oauth/consent still serves the SPA", %{conn: conn} do
      conn = get(conn, "/oauth/consent")
      assert html_response(conn, 200) =~ "window.__ENGRAM_CONFIG__="
    end

    test "/socket/websocket still reaches the transport, unaffected by the deny-list", %{
      conn: conn
    } do
      # socket_dispatch (from the `socket "/socket", EngramWeb.UserSocket`
      # macro in endpoint.ex) claims this exact path BEFORE the router runs,
      # so the new /socket/*path deny entry below it must never see this
      # request. A plain GET with no Upgrade/Origin header hits the
      # transport's own origin check and 403s, same as before this deny
      # entry existed, proving the router-level deny-list never got a
      # chance to intercept it.
      conn = get(conn, "/socket/websocket")
      assert conn.status == 403
    end
  end

  describe "single-segment static_paths() get exact deny entries too" do
    # EngramWeb.static_paths/0 lists favicon.ico, favicon.svg, engram-mark.svg,
    # robots.txt (and email, covered above). These are single-segment, so they
    # need an exact match rather than the /prefix/*path shape used elsewhere in
    # the deny-list. All four real files exist on disk in this test env
    # (priv/static/), so Plug.Static (mounted ahead of the router in the
    # endpoint) always wins for these requests. The tests below prove that is
    # still true, and that a MISS is a clean 404 rather than an HTML 200.
    test "GET /favicon.ico still serves the real file, not the SPA", %{conn: conn} do
      conn = get(conn, "/favicon.ico")
      assert conn.status == 200
      [content_type] = get_resp_header(conn, "content-type")
      refute content_type =~ "text/html"
      refute response(conn, 200) =~ "window.__ENGRAM_CONFIG__="
    end

    test "GET /favicon.svg still serves the real file, not the SPA", %{conn: conn} do
      conn = get(conn, "/favicon.svg")
      assert conn.status == 200
      [content_type] = get_resp_header(conn, "content-type")
      refute content_type =~ "text/html"
      refute response(conn, 200) =~ "window.__ENGRAM_CONFIG__="
    end

    test "GET /engram-mark.svg still serves the real file, not the SPA", %{conn: conn} do
      conn = get(conn, "/engram-mark.svg")
      assert conn.status == 200
      [content_type] = get_resp_header(conn, "content-type")
      refute content_type =~ "text/html"
      refute response(conn, 200) =~ "window.__ENGRAM_CONFIG__="
    end

    test "GET /robots.txt still serves the real file, not the SPA", %{conn: conn} do
      conn = get(conn, "/robots.txt")
      assert conn.status == 200
      [content_type] = get_resp_header(conn, "content-type")
      refute content_type =~ "text/html"
      refute response(conn, 200) =~ "window.__ENGRAM_CONFIG__="
    end

    test "a bogus sibling single-segment path 404s (root is no longer a wildcard)", %{conn: conn} do
      # Before the `/v/` prefix this fell through to `get "/:slug"` and served
      # an HTML 200, because any unrecognized single segment was a candidate
      # vault slug. With vault routes under `/v/`, the root has no wildcard
      # left, so an unknown single segment is simply not a route.
      assert conn |> get("/nonexistent.txt") |> response(404)
    end

    test "on a Plug.Static miss (deploy skew), the router has no route at all" do
      # Plug.Static always wins while the real file exists (proven above), so
      # the only way to see what happens on a deploy-skew miss is to bypass
      # the endpoint's Plug.Static plug and hit the router directly.
      #
      # This used to be covered by explicit `match :*` deny entries, which
      # existed to stop these paths matching the root `get "/:slug"` wildcard
      # and serving an HTML 200. With no root wildcard there is nothing to
      # deny: the router simply has no route, which Plug.Exception maps to
      # 404 and the endpoint renders as JSON (render_errors is json-only).
      # That is a better answer than the deny-list gave -- see
      # docs/context/vault-url-prefix-and-collision-surface.md.
      for path <- ~w(/favicon.ico /favicon.svg /engram-mark.svg /robots.txt) do
        err =
          assert_raise Phoenix.Router.NoRouteError, fn ->
            Phoenix.ConnTest.build_conn(:get, path)
            |> EngramWeb.Router.call(EngramWeb.Router.init([]))
          end

        assert Plug.Exception.status(err) == 404,
               "expected #{path} to map to a 404, got #{Plug.Exception.status(err)}"
      end
    end

    test "and the rendered miss is JSON, not HTML", %{conn: conn} do
      # The raise above proves there is no route; this proves what the
      # ENDPOINT turns that into. Asserted separately because adding
      # `html: ErrorHTML` to render_errors would silently reintroduce the
      # HTML-error-body shape the deny-list was (wrongly) credited with
      # preventing, and the raise-only check could not see it.
      conn = conn |> put_req_header("accept", "application/json") |> get("/assets/missing.js")
      assert conn.status == 404
      [ct] = get_resp_header(conn, "content-type")
      assert ct =~ "application/json"
      refute ct =~ "text/html"
    end
  end

  describe "unrouted paths answer with JSON, not HTML" do
    # The property the deleted deny-list was there to protect, asserted
    # directly instead of via 11 hand-maintained `match :*` entries. An
    # HTML 200 here would mask a broken API call; an HTML *404* would still
    # break a JSON client's parser.
    test "a typo'd API path returns a JSON 404 through the full endpoint", %{conn: conn} do
      conn = conn |> put_req_header("accept", "application/json") |> get("/api/notez")
      assert conn.status == 404
      [ct] = get_resp_header(conn, "content-type")
      assert ct =~ "application/json"
      assert conn.resp_body =~ "Not Found"
    end

    test "a JSON client is not answered with 406", %{conn: conn} do
      # Regression guard for the shape the deny-list actually produced: its
      # routes lived in `pipeline :spa`, whose first plug is
      # `plug :accepts, ["html"]`, so an Accept: application/json request
      # raised Phoenix.NotAcceptableError (406) rather than 404.
      conn = conn |> put_req_header("accept", "application/json") |> get("/api/notez")
      refute conn.status == 406
    end
  end

  defp assert_not_found_not_html(conn) do
    assert response(conn, 404)
    [content_type] = get_resp_header(conn, "content-type")
    refute content_type =~ "text/html"
    conn
  end
end
