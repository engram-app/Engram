defmodule Engram.Auth.TokenResolverTest do
  use Engram.DataCase, async: false

  import Engram.Factory

  alias Engram.Accounts
  alias Engram.Auth.TokenResolver

  # ---- Setup: configure Clerk provider for Clerk JWT tests ----

  setup do
    {_bypass, jwks_url} = Engram.ClerkHelpers.start_jwks_server()

    prev_url = Application.get_env(:engram, :clerk_jwks_url)
    prev_issuer = Application.get_env(:engram, :clerk_issuer)
    prev_provider = Application.get_env(:engram, :auth_provider)

    Application.put_env(:engram, :clerk_jwks_url, jwks_url)
    Application.put_env(:engram, :clerk_issuer, Engram.ClerkHelpers.issuer())
    Application.put_env(:engram, :auth_provider, :clerk)

    start_supervised!({Engram.Auth.ClerkStrategy, time_interval: 60_000, first_fetch_sync: true})

    on_exit(fn ->
      if prev_url,
        do: Application.put_env(:engram, :clerk_jwks_url, prev_url),
        else: Application.delete_env(:engram, :clerk_jwks_url)

      if prev_issuer,
        do: Application.put_env(:engram, :clerk_issuer, prev_issuer),
        else: Application.delete_env(:engram, :clerk_issuer)

      Application.put_env(:engram, :auth_provider, prev_provider || :local)
    end)

    :ok
  end

  # ---- API key (works regardless of provider) ----

  test "resolves a valid API key to a user" do
    user = insert(:user)
    {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "test key")

    assert {:ok, resolved, _api_key} = TokenResolver.resolve(raw_key)
    assert resolved.id == user.id
  end

  test "rejects an invalid API key" do
    assert {:error, _reason} = TokenResolver.resolve("engram_notarealkey")
  end

  # ---- Clerk JWT (provider: clerk) ----

  test "resolves a valid Clerk JWT, creating the user on first use" do
    claims = Engram.ClerkHelpers.clerk_claims("clerk_new_user_xyz", email: "new@clerk.example")
    token = Engram.ClerkHelpers.sign_clerk_jwt(claims)

    assert {:ok, user} = TokenResolver.resolve(token)
    assert user.external_id == "clerk_new_user_xyz"
    assert user.email == "new@clerk.example"
  end

  test "resolves a valid Clerk JWT for an existing Clerk user" do
    clerk_id = "clerk_existing_abc"
    existing = insert(:user, external_id: clerk_id, email: "existing@clerk.example")

    claims = Engram.ClerkHelpers.clerk_claims(clerk_id, email: existing.email)
    token = Engram.ClerkHelpers.sign_clerk_jwt(claims)

    assert {:ok, user} = TokenResolver.resolve(token)
    assert user.id == existing.id
  end

  @tag capture_log: true
  test "rejects an expired Clerk JWT" do
    claims =
      Engram.ClerkHelpers.clerk_claims("clerk_exp_user",
        exp: :os.system_time(:second) - 60
      )

    token = Engram.ClerkHelpers.sign_clerk_jwt(claims)

    assert {:error, _reason} = TokenResolver.resolve(token)
  end

  # ---- Local JWT (provider: local) ----

  test "resolves a valid local JWT when provider is local" do
    Application.put_env(:engram, :auth_provider, :local)

    {:ok, %{external_id: ext_id}} =
      Engram.Auth.Providers.Local.register_user("local@test.com", "StrongPass123!", %{})

    {:ok, token} = Engram.Auth.Providers.Local.issue_access_token(ext_id, "local@test.com")

    assert {:ok, user} = TokenResolver.resolve(token)
    assert user.external_id == ext_id
    assert user.email == "local@test.com"
  end

  # ---- Internal JWT / device flow (always available as fallback) ----

  test "resolves a valid internal JWT (device flow token) when provider is clerk" do
    user = insert(:user)
    token = Accounts.generate_jwt(user)

    # Internal-JWT path now returns a 3-tuple with `:internal_jwt` so
    # downstream plugs can tell device-flow / OAuth / MCP access apart
    # from Clerk-authed web-SPA traffic.
    assert {:ok, resolved, :internal_jwt} = TokenResolver.resolve(token)
    assert resolved.id == user.id
  end

  test "rejects a tampered internal JWT" do
    assert {:error, _reason} = TokenResolver.resolve("not.a.valid.jwt")
  end

  # ---- Edge cases ----

  test "rejects nil" do
    assert {:error, :invalid_token} = TokenResolver.resolve(nil)
  end

  test "rejects a non-string value" do
    assert {:error, :invalid_token} = TokenResolver.resolve(12_345)
  end

  test "rejects an empty string" do
    assert {:error, _reason} = TokenResolver.resolve("")
  end
end
