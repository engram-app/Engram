defmodule Engram.AccountsTest do
  use Engram.DataCase, async: true

  alias Engram.Accounts

  describe "API keys" do
    setup do
      user = insert(:user)
      %{user: user}
    end

    test "create_api_key returns raw key with engram_ prefix", %{user: user} do
      assert {:ok, raw_key, api_key} = Accounts.create_api_key(user, "test key")
      assert String.starts_with?(raw_key, "engram_")
      assert api_key.name == "test key"
      assert api_key.user_id == user.id
    end

    test "validate_api_key finds key by hash", %{user: user} do
      {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "validate test")
      assert {:ok, found_user, _api_key} = Accounts.validate_api_key(raw_key)
      assert found_user.id == user.id
    end

    test "validate_api_key rejects invalid key" do
      assert {:error, :invalid_key} = Accounts.validate_api_key("engram_bogus")
    end

    test "list_api_keys returns user's keys", %{user: user} do
      Accounts.create_api_key(user, "key1")
      Accounts.create_api_key(user, "key2")
      keys = Accounts.list_api_keys(user)
      assert length(keys) == 2
    end

    test "revoke_api_key deletes the key", %{user: user} do
      {:ok, _raw, api_key} = Accounts.create_api_key(user, "to revoke")
      assert :ok = Accounts.revoke_api_key(user, api_key.id)
      assert Accounts.list_api_keys(user) == []
    end
  end

  describe "find_or_create_by_external_id/2" do
    test "returns existing user when external_id matches" do
      user = insert(:user, email: "existing@test.com")

      # Manually set external_id (simulating a previous Clerk login)
      user
      |> Ecto.Changeset.change(%{external_id: "clerk_user_abc"})
      |> Engram.Repo.update!(skip_tenant_check: true)

      assert {:ok, found} =
               Accounts.find_or_create_by_external_id("clerk_user_abc", %{
                 email: "existing@test.com"
               })

      assert found.id == user.id
      assert found.external_id == "clerk_user_abc"
    end

    test "links external_id to existing user matched by email" do
      user = insert(:user, email: "link@test.com")

      assert {:ok, linked} =
               Accounts.find_or_create_by_external_id("clerk_user_link", %{
                 email: "link@test.com"
               })

      assert linked.id == user.id
      assert linked.external_id == "clerk_user_link"
    end

    test "creates new user when no external_id or email match" do
      assert {:ok, created} =
               Accounts.find_or_create_by_external_id("clerk_user_new", %{
                 email: "brand_new@test.com"
               })

      assert created.external_id == "clerk_user_new"
      assert created.email == "brand_new@test.com"
    end

    test "returns existing user even if email changed in provider" do
      user = insert(:user, email: "old@test.com")

      user
      |> Ecto.Changeset.change(%{external_id: "clerk_stable"})
      |> Engram.Repo.update!(skip_tenant_check: true)

      # Provider reports a different email, but external_id is the same
      assert {:ok, found} =
               Accounts.find_or_create_by_external_id("clerk_stable", %{
                 email: "new@test.com"
               })

      assert found.id == user.id
      # external_id lookup takes precedence — email is NOT updated
      assert found.email == "old@test.com"
    end
  end

  describe "refresh tokens" do
    setup do
      user = insert(:user)
      %{user: user}
    end

    test "create and consume refresh token round-trip", %{user: user} do
      {:ok, raw_token, record} = Accounts.create_refresh_token(user)

      assert is_binary(raw_token)
      assert record.user_id == user.id
      refute is_nil(record.family_id)

      assert {:ok, same_user, new_raw, _new_record} = Accounts.consume_refresh_token(raw_token)
      assert same_user.id == user.id
      assert new_raw != raw_token
    end

    test "rejects completely invalid token" do
      assert {:error, :invalid_token} = Accounts.consume_refresh_token("bogus_token")
    end

    test "reuse of revoked token triggers family-wide revocation", %{user: user} do
      {:ok, raw_token, _record} = Accounts.create_refresh_token(user)

      # Consume once — rotates to a new token
      {:ok, _user, new_raw, _new_record} = Accounts.consume_refresh_token(raw_token)

      # Replay the OLD token — should detect reuse and revoke the family
      assert {:error, :token_reused} = Accounts.consume_refresh_token(raw_token)

      # The rotated token should ALSO be revoked (entire family)
      assert {:error, :token_reused} = Accounts.consume_refresh_token(new_raw)
    end

    test "expired refresh token is rejected", %{user: user} do
      {:ok, raw_token, record} = Accounts.create_refresh_token(user)

      # Manually expire the token
      import Ecto.Query

      from(rt in Engram.Auth.RefreshToken, where: rt.id == ^record.id)
      |> Engram.Repo.update_all(
        [
          set: [
            expires_at:
              DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)
          ]
        ],
        skip_tenant_check: true
      )

      assert {:error, :expired} = Accounts.consume_refresh_token(raw_token)
    end
  end

  describe "JWT" do
    test "generate and verify token round-trip" do
      user = insert(:user)

      token = Accounts.generate_jwt(user)
      assert {:ok, claims} = Accounts.verify_jwt(token)
      assert claims["user_id"] == user.id
    end

    test "rejects tampered token" do
      assert {:error, _reason} = Accounts.verify_jwt("garbage.token.here")
    end

    test "includes sub (external_id) and email so the active auth provider accepts the token" do
      # Regression: device flow mints access tokens via Accounts.generate_jwt/1.
      # If sub/email are missing, the Local provider rejects them with
      # :missing_claims and authenticated requests 401 in a refresh loop.
      user = insert(:user, external_id: "user-ext-abc", email: "alice@example.com")

      token = Accounts.generate_jwt(user)
      {:ok, claims} = Accounts.verify_jwt(token)

      assert claims["sub"] == "user-ext-abc"
      assert claims["email"] == "alice@example.com"
      assert claims["user_id"] == user.id
    end

    test "device-flow tokens are accepted by Local provider verify_token" do
      user = insert(:user, external_id: "user-ext-xyz", email: "bob@example.com")

      token = Accounts.generate_jwt(user)

      assert {:ok, %{external_id: "user-ext-xyz", email: "bob@example.com"}} =
               Engram.Auth.Providers.Local.verify_token(token)
    end
  end
end
