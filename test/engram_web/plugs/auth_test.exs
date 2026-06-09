defmodule EngramWeb.Plugs.AuthTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Accounts
  alias Engram.Test.LogCapture
  alias EngramWeb.Plugs.Auth

  setup do
    user = insert(:user)
    {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "test")

    %{user: user, raw_key: raw_key}
  end

  test "authenticates with valid API key", %{user: user, raw_key: raw_key} do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> Auth.call([])

    assert conn.assigns.current_user.id == user.id
    refute conn.halted
  end

  test "preloads the subscription assoc when billing is enabled", %{user: user, raw_key: raw_key} do
    prev_enabled = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, true)
    on_exit(fn -> Application.put_env(:engram, :billing_enabled, prev_enabled) end)

    insert(:subscription, user: user, tier: "pro", status: "active")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> Auth.call([])

    sub = conn.assigns.current_user.subscription
    refute match?(%Ecto.Association.NotLoaded{}, sub)
    assert sub.tier == "pro"
  end

  test "does not preload the subscription in self-host mode (billing disabled)", %{
    user: user,
    raw_key: raw_key
  } do
    prev_enabled = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, false)
    on_exit(fn -> Application.put_env(:engram, :billing_enabled, prev_enabled) end)

    insert(:subscription, user: user, tier: "pro", status: "active")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> Auth.call([])

    assert match?(%Ecto.Association.NotLoaded{}, conn.assigns.current_user.subscription)
  end

  test "authenticates with valid local JWT" do
    Application.put_env(:engram, :auth_provider, :local)

    on_exit(fn -> Application.put_env(:engram, :auth_provider, :local) end)

    {:ok, %{external_id: ext_id}} =
      Engram.Auth.Providers.Local.register_user("plugtest@example.com", "StrongPass123!", %{})

    {:ok, token} = Engram.Auth.Providers.Local.issue_access_token(ext_id, "plugtest@example.com")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> Auth.call([])

    assert conn.assigns.current_user.external_id == ext_id
    refute conn.halted
  end

  # The Auth plug's 3rd-tuple branch (`{:ok, user, :internal_jwt}` →
  # assign(:current_auth_method)) is covered by
  # `Engram.Auth.TokenResolverTest` end-to-end — that test sets up a
  # Clerk bypass so the fallback path actually fires. Reproducing the
  # bypass here just to assert one assign would duplicate ~30 lines of
  # provider setup. The plug's `case` branch is a literal pattern
  # match; the contract on the TokenResolver side is the thing that
  # needs locking.

  test "rejects missing auth header" do
    conn =
      build_conn()
      |> Auth.call([])

    assert conn.status == 401
    assert conn.halted
  end

  test "rejects invalid API key" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer engram_invalid")
      |> Auth.call([])

    assert conn.status == 401
    assert conn.halted
  end

  test "rejects invalid JWT" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer not.a.jwt")
      |> Auth.call([])

    assert conn.status == 401
    assert conn.halted
  end

  describe "401 logging" do
    setup do
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)
      :ok
    end

    test "logs claim_invalid:exp when access token is expired" do
      claims = %{
        "user_id" => 1,
        "iss" => "engram",
        "aud" => "engram",
        "exp" => Joken.current_time() - 60
      }

      signer = Joken.Signer.create("HS256", Application.get_env(:joken, :default_signer))
      {:ok, expired_token} = Joken.Signer.sign(claims, signer)

      {_conn, events} =
        LogCapture.with_events(fn ->
          build_conn()
          |> put_req_header("authorization", "Bearer #{expired_token}")
          |> Auth.call([])
        end)

      assert Enum.any?(events, fn e ->
               match?({:string, "auth rejected"}, e.msg) and
                 e.meta[:reason] == "claim_invalid:exp"
             end),
             "expected an auth-rejected event with reason=claim_invalid:exp, got: #{inspect(events)}"
    end

    test "logs no_auth when authorization header is missing" do
      {_conn, events} =
        LogCapture.with_events(fn ->
          build_conn() |> Auth.call([])
        end)

      assert Enum.any?(events, fn e ->
               match?({:string, "auth rejected"}, e.msg) and e.meta[:reason] == "no_auth"
             end),
             "expected an auth-rejected event with reason=no_auth, got: #{inspect(events)}"
    end

    test "scrubs request_path metadata via the global redact filter" do
      sentinel = "/api/notes/secret-folder/XYZZYZ-LOGTEST-confidential.md"

      {_conn, events} =
        LogCapture.with_events(fn ->
          conn = build_conn()
          %{conn | request_path: sentinel} |> Auth.call([])
        end)

      auth_event = Enum.find(events, &match?({:string, "auth rejected"}, &1.msg))
      assert auth_event, "expected an 'auth rejected' event"

      assert auth_event.meta[:request_path] == "[REDACTED]",
             "expected request_path to be redacted by the primary filter, got: #{inspect(auth_event.meta)}"

      refute auth_event.meta |> inspect() =~ "XYZZYZ-LOGTEST"
    end
  end

  test "returns 401 for JWT referencing deleted user" do
    user = insert(:user)
    jwt = Accounts.generate_jwt(user)

    # Delete the user directly from the DB
    Engram.Repo.delete(user, skip_tenant_check: true)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{jwt}")
      |> Auth.call([])

    assert conn.status == 401
    assert conn.halted
  end

  describe "Clerk JWT authentication" do
    setup do
      {bypass, jwks_url} = Engram.ClerkHelpers.start_jwks_server()

      prev_provider = Application.get_env(:engram, :auth_provider)

      Application.put_env(:engram, :clerk_jwks_url, jwks_url)
      Application.put_env(:engram, :clerk_issuer, Engram.ClerkHelpers.issuer())
      Application.put_env(:engram, :auth_provider, :clerk)

      start_supervised!(
        {Engram.Auth.ClerkStrategy, time_interval: 60_000, first_fetch_sync: true}
      )

      on_exit(fn ->
        Application.delete_env(:engram, :clerk_jwks_url)
        Application.delete_env(:engram, :clerk_issuer)
        Application.put_env(:engram, :auth_provider, prev_provider || :local)
      end)

      %{bypass: bypass}
    end

    test "authenticates with valid Clerk JWT and creates user" do
      claims =
        Engram.ClerkHelpers.clerk_claims("clerk_new_user", email: "clerktest@example.com")

      token = Engram.ClerkHelpers.sign_clerk_jwt(claims)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> Auth.call([])

      refute conn.halted
      assert conn.assigns.current_user.external_id == "clerk_new_user"
      assert conn.assigns.current_user.email == "clerktest@example.com"
    end

    test "authenticates with Clerk JWT and finds existing user by external_id" do
      user = insert(:user, email: "existing_clerk@test.com")

      user
      |> Ecto.Changeset.change(%{external_id: "clerk_existing"})
      |> Engram.Repo.update!(skip_tenant_check: true)

      claims =
        Engram.ClerkHelpers.clerk_claims("clerk_existing", email: "existing_clerk@test.com")

      token = Engram.ClerkHelpers.sign_clerk_jwt(claims)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> Auth.call([])

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
    end

    @tag capture_log: true
    test "rejects invalid Clerk JWT" do
      # Sign with wrong key
      other_jwk = JOSE.JWK.generate_key({:rsa, 2048})
      jws = %{"alg" => "RS256", "kid" => "bad-key"}
      claims = Engram.ClerkHelpers.clerk_claims("bad_user")

      {_alg, token} =
        JOSE.JWK.sign(Jason.encode!(claims), jws, other_jwk)
        |> JOSE.JWS.compact()

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> Auth.call([])

      assert conn.status == 401
      assert conn.halted
    end
  end
end
