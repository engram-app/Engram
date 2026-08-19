defmodule EngramWeb.LocalAuthControllerTest do
  # async: false — tests mutate global Application config
  use EngramWeb.ConnCase, async: false

  setup do
    prev = Application.get_env(:engram, :auth_provider)
    Application.put_env(:engram, :auth_provider, :local)
    on_exit(fn -> Application.put_env(:engram, :auth_provider, prev || :local) end)
    :ok
  end

  # Swap the endpoint's canonical URL for the duration of `fun`. The refresh
  # cookie's `secure` flag is derived from it, so this is the real lever a
  # deployment pulls (PHX_HOST / PHX_SCHEME in runtime.exs).
  #
  # `Endpoint.url/0` is served from a persistent_term warmed off the endpoint's
  # ETS config, NOT from Application env, so `put_env` alone is invisible to
  # it. `config_change/2` is the supported path: it updates the ETS table and
  # re-warms. Restored on the way out so a failure cannot leak a bogus URL into
  # later tests (this file is already `async: false`).
  defp with_endpoint_url(url, fun) do
    %{scheme: scheme, host: host, port: port} = URI.parse(url)
    prev = Application.get_env(:engram, EngramWeb.Endpoint)
    next = Keyword.put(prev, :url, host: host, port: port, scheme: scheme)

    apply_url = fn cfg ->
      Application.put_env(:engram, EngramWeb.Endpoint, cfg)
      EngramWeb.Endpoint.config_change([{EngramWeb.Endpoint, cfg}], [])
    end

    apply_url.(next)

    try do
      fun.()
    after
      apply_url.(prev)
    end
  end

  describe "POST /api/auth/register" do
    test "creates user and returns access token + refresh cookie", %{conn: conn} do
      conn =
        post(conn, "/api/auth/register", %{email: "new@test.com", password: "StrongPass123!"})

      assert %{"access_token" => token, "user" => %{"email" => "new@test.com", "role" => "admin"}} =
               json_response(conn, 201)

      assert is_binary(token)
      cookie = conn.resp_cookies["refresh_token"]
      assert cookie
      assert cookie.http_only == true
      assert cookie.same_site == "Lax"
    end

    test "refresh cookie is Secure when the canonical URL is https", %{conn: conn} do
      # The app never sees TLS: it listens plaintext behind an edge, so
      # `conn.scheme` is :http even for a user who arrived over HTTPS. Deriving
      # the flag from the conn shipped this 30-day token with no `Secure`
      # attribute, letting a downgrade replay it over cleartext.
      #
      # Note this asserts on the URL config, NOT on `x-forwarded-proto`. A
      # header-derived fix passes a test like this while silently failing on
      # the header shapes real proxy chains emit (uppercase `HTTPS`, or the
      # appended `https,http` a CDN in front of nginx produces) — `RewriteOn`
      # matches the literal lowercase "https" only and otherwise falls through
      # to a bare conn with no log and no error.
      with_endpoint_url("https://engram.example", fn ->
        conn =
          %{conn | host: "engram.example"}
          |> post("/api/auth/register", %{email: "tls@test.com", password: "StrongPass123!"})

        assert json_response(conn, 201)
        assert conn.resp_cookies["refresh_token"].secure == true
      end)
    end

    test "refresh cookie is not Secure when the canonical URL is http", %{conn: conn} do
      # The other direction: a genuinely plaintext deployment must NOT get a
      # Secure cookie, or local http logins break silently (the browser simply
      # withholds the cookie on the next request).
      with_endpoint_url("http://localhost:4000", fn ->
        conn =
          post(conn, "/api/auth/register", %{email: "plain@test.com", password: "StrongPass123!"})

        assert json_response(conn, 201)
        refute conn.resp_cookies["refresh_token"].secure
      end)
    end

    test "Secure is set on a NON-canonical host too", %{conn: conn} do
      # Pins the deliberate trade-off, because the obvious "fix" is to make this
      # test's assertion the opposite.
      #
      # PHX_HOST is comma-separated with the first entry canonical
      # (`.env.example` ships `engram.example.com,10.0.20.5:4000`), and
      # HostOrigins admits http AND https for every entry, so a self-host box is
      # routinely reachable on several names at once. An earlier version keyed
      # `secure` off `conn.host == canonical_host` so the plaintext LAN alias
      # kept working — and thereby dropped Secure on any OTHER TLS hostname,
      # handing out a 30-day refresh token in the clear on a host that was
      # perfectly capable of protecting it. SameSite=Lax does not cover that:
      # Lax still rides top-level navigations, so a forced navigation to
      # http://other-host/api/auth/refresh leaks it to the wire.
      #
      # The credential wins. A canonically-HTTPS deployment marks every refresh
      # cookie Secure, whatever host was dialed. The accepted cost is that a
      # plaintext alias can no longer persist a login: the browser takes the 201
      # and the access token, silently discards the Secure cookie, and
      # /api/auth/refresh 401s once the access token expires. Operators fix that
      # by serving the alias over TLS, not by reintroducing the host check.
      with_endpoint_url("https://engram.example", fn ->
        conn =
          %{conn | host: "10.0.20.5"}
          |> post("/api/auth/register", %{email: "lan@test.com", password: "StrongPass123!"})

        assert json_response(conn, 201)
        assert conn.resp_cookies["refresh_token"].secure == true
      end)
    end

    test "login and refresh rotation set Secure too, not just register", %{conn: conn} do
      # All three sites share `refresh_cookie_opts/1`, but only `register` was
      # covered before. The rotation cookie is the longest-lived credential in
      # the flow, so it is the one that most needs pinning.
      #
      # Each conn dials the canonical host explicitly: `build_conn/0` defaults
      # to `www.example.com`, which is (correctly) a non-canonical host and
      # would yield `secure: false` for reasons unrelated to what this test is
      # about.
      with_endpoint_url("https://engram.example", fn ->
        %{conn | host: "engram.example"}
        |> post("/api/auth/register", %{email: "all@test.com", password: "StrongPass123!"})

        login =
          %{build_conn() | host: "engram.example"}
          |> post("/api/auth/login", %{
            email: "all@test.com",
            password: "StrongPass123!"
          })

        assert json_response(login, 200)
        assert login.resp_cookies["refresh_token"].secure == true

        rotated =
          %{build_conn() | host: "engram.example"}
          |> put_req_cookie("refresh_token", login.resp_cookies["refresh_token"].value)
          |> post("/api/auth/refresh")

        assert json_response(rotated, 200)
        assert rotated.resp_cookies["refresh_token"].secure == true
      end)
    end

    test "first user is admin, second is member", %{conn: conn} do
      post(conn, "/api/auth/register", %{email: "first@test.com", password: "StrongPass123!"})
      # Default mode is invite_only; open up so the second signup isn't gated.
      {:ok, _} = Engram.Instance.set_registration_mode("open")

      conn2 =
        post(build_conn(), "/api/auth/register", %{
          email: "second@test.com",
          password: "StrongPass123!"
        })

      assert %{"user" => %{"role" => "member"}} = json_response(conn2, 201)
    end

    test "rejects duplicate email with generic error", %{conn: conn} do
      post(conn, "/api/auth/register", %{email: "dup@test.com", password: "StrongPass123!"})
      {:ok, _} = Engram.Instance.set_registration_mode("open")

      conn2 =
        post(build_conn(), "/api/auth/register", %{
          email: "dup@test.com",
          password: "StrongPass123!"
        })

      assert %{"error" => "registration_failed"} = json_response(conn2, 422)
    end

    test "rejects short password with specific error", %{conn: conn} do
      conn = post(conn, "/api/auth/register", %{email: "short@test.com", password: "abc"})

      assert %{"error" => "password_too_short"} = json_response(conn, 422)
    end

    test "rejects password over 72 bytes", %{conn: conn} do
      conn =
        post(conn, "/api/auth/register", %{
          email: "long@test.com",
          password: String.duplicate("a", 73)
        })

      assert %{"error" => "password_too_long"} = json_response(conn, 422)
    end

    test "rejects missing fields", %{conn: conn} do
      conn = post(conn, "/api/auth/register", %{email: "no@pass.com"})

      assert %{"error" => "email and password required"} = json_response(conn, 422)
    end
  end

  describe "POST /api/auth/login" do
    setup %{conn: conn} do
      post(conn, "/api/auth/register", %{email: "login@test.com", password: "StrongPass123!"})
      :ok
    end

    test "returns access token + refresh cookie for valid credentials", %{conn: conn} do
      conn = post(conn, "/api/auth/login", %{email: "login@test.com", password: "StrongPass123!"})

      assert %{"access_token" => token} = json_response(conn, 200)
      assert is_binary(token)
      assert conn.resp_cookies["refresh_token"]
    end

    test "rejects wrong password with generic error", %{conn: conn} do
      conn = post(conn, "/api/auth/login", %{email: "login@test.com", password: "WrongPass!"})

      assert %{"error" => "invalid_credentials"} = json_response(conn, 401)
    end

    test "rejects nonexistent user with generic error", %{conn: conn} do
      conn = post(conn, "/api/auth/login", %{email: "nobody@test.com", password: "Whatever!"})

      assert %{"error" => "invalid_credentials"} = json_response(conn, 401)
    end

    test "rejects suspended account with account_suspended (distinct from invalid_credentials)",
         %{conn: conn} do
      # describe-level setup already registered login@test.com (admin) and
      # closed bootstrap. Open registration so we can sign up the victim.
      {:ok, _} = Engram.Instance.set_registration_mode("open")

      post(build_conn(), "/api/auth/register", %{
        email: "sus@test.com",
        password: "StrongPass123!"
      })

      user =
        Engram.Repo.get_by!(Engram.Accounts.User, [email: "sus@test.com"],
          skip_tenant_check: true
        )

      {:ok, _} = Engram.Accounts.suspend(user)

      conn = post(conn, "/api/auth/login", %{email: "sus@test.com", password: "StrongPass123!"})

      assert %{"error" => "account_suspended"} = json_response(conn, 403)
    end
  end

  describe "POST /api/auth/refresh" do
    test "issues new access token from refresh cookie", %{conn: conn} do
      register_conn =
        post(conn, "/api/auth/register", %{email: "refresh@test.com", password: "StrongPass123!"})

      cookie = register_conn.resp_cookies["refresh_token"]

      conn2 =
        build_conn()
        |> put_req_cookie("refresh_token", cookie.value)
        |> post("/api/auth/refresh")

      assert %{"access_token" => new_token} = json_response(conn2, 200)
      assert is_binary(new_token)
      assert conn2.resp_cookies["refresh_token"]
      assert conn2.resp_cookies["refresh_token"].value != cookie.value
    end

    test "rejects missing cookie", %{conn: conn} do
      conn = post(conn, "/api/auth/refresh")

      assert %{"error" => "no_refresh_token"} = json_response(conn, 401)
    end
  end

  describe "POST /api/auth/logout" do
    test "clears refresh cookie", %{conn: conn} do
      register_conn =
        post(conn, "/api/auth/register", %{email: "logout@test.com", password: "StrongPass123!"})

      cookie = register_conn.resp_cookies["refresh_token"]

      conn2 =
        build_conn()
        |> put_req_cookie("refresh_token", cookie.value)
        |> post("/api/auth/logout")

      assert response(conn2, 204)
      assert conn2.resp_cookies["refresh_token"].max_age == 0
    end
  end

  describe "RequireLocalAuth plug" do
    test "returns 404 when auth_provider is clerk", %{conn: conn} do
      Application.put_env(:engram, :auth_provider, :clerk)

      conn =
        post(conn, "/api/auth/register", %{email: "blocked@test.com", password: "StrongPass123!"})

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "allows requests when auth_provider is local", %{conn: conn} do
      conn =
        post(conn, "/api/auth/register", %{email: "allowed@test.com", password: "StrongPass123!"})

      assert json_response(conn, 201)
    end
  end

  describe "GET /api/auth/invite/:token" do
    test "previews a valid invite", %{conn: conn} do
      admin = insert(:user, role: "admin")
      {:ok, {raw, _}} = Engram.Invites.create_invite(admin, %{label: "Family"})
      conn = get(conn, ~p"/api/auth/invite/#{raw}")
      body = json_response(conn, 200)
      assert body["valid"] == true
      assert body["label"] == "Family"
    end

    test "reports invalid for an unknown token (non-enumerating)", %{conn: conn} do
      conn = get(conn, ~p"/api/auth/invite/garbage")
      assert json_response(conn, 200)["valid"] == false
    end
  end

  describe "GET /api/auth/bootstrap" do
    test "reports bootstrap_pending=true on a fresh instance", %{conn: conn} do
      body = json_response(get(conn, ~p"/api/auth/bootstrap"), 200)
      assert body["bootstrap_pending"] == true
      assert body["registration_mode"] in ~w(closed invite_only open)
    end

    test "reports bootstrap_pending=false after mark_bootstrap_complete", %{conn: conn} do
      {:ok, _} = Engram.Instance.mark_bootstrap_complete()
      body = json_response(get(conn, ~p"/api/auth/bootstrap"), 200)
      assert body["bootstrap_pending"] == false
    end

    test "returns 404 under Clerk", %{conn: conn} do
      Application.put_env(:engram, :auth_provider, :clerk)
      assert %{"error" => "not_found"} = json_response(get(conn, ~p"/api/auth/bootstrap"), 404)
    end
  end

  describe "POST /api/auth/register — registration control" do
    test "first signup becomes admin regardless of mode (claim window)", %{conn: conn} do
      {:ok, _} = Engram.Instance.set_registration_mode("closed")

      conn =
        post(conn, ~p"/api/auth/register", %{email: "boss@x.com", password: "longpassword1"})

      assert json_response(conn, 201)["user"]["role"] == "admin"
    end

    test "second signup is rejected when mode=closed", %{conn: conn} do
      _ = insert(:user, role: "admin")
      {:ok, _} = Engram.Instance.mark_bootstrap_complete()
      {:ok, _} = Engram.Instance.set_registration_mode("closed")

      conn =
        post(conn, ~p"/api/auth/register", %{email: "b@x.com", password: "longpassword1"})

      assert json_response(conn, 403)["error"] == "registration_closed"
    end

    test "open mode lets anyone register as member", %{conn: conn} do
      _ = insert(:user, role: "admin")
      {:ok, _} = Engram.Instance.mark_bootstrap_complete()
      {:ok, _} = Engram.Instance.set_registration_mode("open")

      conn =
        post(conn, ~p"/api/auth/register", %{email: "c@x.com", password: "longpassword1"})

      assert json_response(conn, 201)["user"]["role"] == "member"
    end

    test "invite_only rejects without a token", %{conn: conn} do
      _ = insert(:user, role: "admin")
      {:ok, _} = Engram.Instance.mark_bootstrap_complete()
      {:ok, _} = Engram.Instance.set_registration_mode("invite_only")

      conn =
        post(conn, ~p"/api/auth/register", %{email: "d@x.com", password: "longpassword1"})

      assert json_response(conn, 403)["error"] == "invite_required"
    end

    test "invite_only accepts a valid token and consumes it", %{conn: conn} do
      admin = insert(:user, role: "admin")
      {:ok, _} = Engram.Instance.mark_bootstrap_complete()
      {:ok, _} = Engram.Instance.set_registration_mode("invite_only")
      {:ok, {raw, _}} = Engram.Invites.create_invite(admin, %{})

      conn =
        post(conn, ~p"/api/auth/register", %{
          email: "e@x.com",
          password: "longpassword1",
          invite: raw
        })

      assert json_response(conn, 201)["user"]["role"] == "member"
      assert Engram.Invites.preview(raw) == %{valid: false}
    end

    test "invite_only rejects a bad token", %{conn: conn} do
      _ = insert(:user, role: "admin")
      {:ok, _} = Engram.Instance.mark_bootstrap_complete()
      {:ok, _} = Engram.Instance.set_registration_mode("invite_only")

      conn =
        post(conn, ~p"/api/auth/register", %{
          email: "f@x.com",
          password: "longpassword1",
          invite: "garbage"
        })

      assert json_response(conn, 403)["error"] == "invite_invalid"
    end
  end
end
