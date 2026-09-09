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

  # ---- Rejection reason fidelity ----
  #
  # A Clerk failure that is NOT a signature failure used to fall through the
  # `{:error, _}` catch-all into the internal HS256 verifier, which of course
  # also failed — and ITS error is what got logged. Every expired/wrong-azp
  # Clerk token was therefore reported as `signature_error`, which sent a prod
  # investigation of 6753 rejections at the wrong root cause entirely.
  #
  # Both cases below can only be reached AFTER the RS256 signature verified, so
  # the token is provably a genuine Clerk token and must never be retried as an
  # internal JWT.

  @tag capture_log: true
  test "an expired Clerk JWT reports the expired claim, not a signature error" do
    claims =
      Engram.ClerkHelpers.clerk_claims("clerk_exp_user", exp: :os.system_time(:second) - 60)

    token = Engram.ClerkHelpers.sign_clerk_jwt(claims)

    assert {:error, reason} = TokenResolver.resolve(token)
    assert Engram.Auth.rejection_label(reason) == "claim_invalid:exp"
  end

  @tag capture_log: true
  test "a Clerk JWT from an unauthorized party reports invalid_azp" do
    prev = Application.get_env(:engram, :clerk_authorized_parties)
    Application.put_env(:engram, :clerk_authorized_parties, ["https://app.engram.page"])

    on_exit(fn ->
      if prev,
        do: Application.put_env(:engram, :clerk_authorized_parties, prev),
        else: Application.delete_env(:engram, :clerk_authorized_parties)
    end)

    claims = Engram.ClerkHelpers.clerk_claims("clerk_azp_user", azp: "https://evil.example")
    token = Engram.ClerkHelpers.sign_clerk_jwt(claims)

    assert {:error, reason} = TokenResolver.resolve(token)
    assert Engram.Auth.rejection_label(reason) == "invalid_azp"
  end

  # The fallback itself must survive: a token the Clerk provider cannot verify
  # at all is still retried as an internal JWT, and only reports a signature
  # failure once THAT also fails.
  @tag capture_log: true
  test "a token the Clerk provider cannot verify still falls through to internal JWT" do
    user = insert(:user)
    assert {:ok, resolved, :internal_jwt} = TokenResolver.resolve(Accounts.generate_jwt(user))
    assert resolved.id == user.id

    assert {:error, reason} = TokenResolver.resolve("not.a.valid.jwt")
    assert Engram.Auth.rejection_label(reason) == "signature_error"
  end

  # A Clerk signing-key ROTATION is the scenario the original 6753-line
  # investigation was misdirected toward, and it was the one case the first
  # version of `conclusive?/1` still could not see. JokenJwks returns
  # `:kid_does_not_match` when the token's kid is absent from the JWKS.
  #
  # Safe to treat as conclusive because `JokenJwks.before_verify/2` extracts the
  # kid BEFORE looking up a signer: a token with no kid at all halts earlier
  # with `:no_kid_in_token_header`. Our internal HS256 JWTs carry no kid, so
  # they can never reach this branch — which is what the fall-through test
  # below pins down.
  @tag capture_log: true
  test "a Clerk JWT signed with an unknown kid reports the kid mismatch" do
    claims = Engram.ClerkHelpers.clerk_claims("clerk_rotated_key_user")
    token = Engram.ClerkHelpers.sign_clerk_jwt_with_kid(claims, "rotated-key-99")

    assert {:error, reason} = TokenResolver.resolve(token)
    assert Engram.Auth.rejection_label(reason) == "kid_does_not_match"
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
