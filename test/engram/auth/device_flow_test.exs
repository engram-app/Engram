defmodule Engram.Auth.DeviceFlowTest do
  use Engram.DataCase, async: true

  import Ecto.Query

  alias Engram.Auth.{DeviceFlow, DeviceRefreshToken}
  alias Engram.Repo

  describe "start_device_flow/1" do
    test "creates a pending device authorization" do
      assert {:ok, auth} = DeviceFlow.start_device_flow("test_client_id")
      assert auth.status == "pending"
      assert auth.client_id == "test_client_id"
      assert byte_size(auth.device_code) == 64

      assert String.match?(
               auth.user_code,
               ~r/^[ABCDEFGHJKMNPQRSTUVWXYZ2345679]{4}-[ABCDEFGHJKMNPQRSTUVWXYZ2345679]{4}$/
             )

      assert DateTime.compare(auth.expires_at, DateTime.utc_now()) == :gt
    end

    test "generates unique device codes" do
      {:ok, auth1} = DeviceFlow.start_device_flow("client1")
      {:ok, auth2} = DeviceFlow.start_device_flow("client2")
      assert auth1.device_code != auth2.device_code
      assert auth1.user_code != auth2.user_code
    end

    test "stores optional vault_name hint" do
      assert {:ok, auth} = DeviceFlow.start_device_flow("client_1", "Local Vault")
      assert auth.vault_name == "Local Vault"
    end

    test "defaults vault_name to nil when omitted" do
      assert {:ok, auth} = DeviceFlow.start_device_flow("client_1")
      assert auth.vault_name == nil
    end
  end

  describe "suggested_vault_name/2" do
    test "returns the hint stored at start time for a pending code" do
      reader = insert(:user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1", "Brainvault")
      assert DeviceFlow.suggested_vault_name(auth.user_code, reader.id) == "Brainvault"
    end

    test "returns nil for unknown code" do
      reader = insert(:user)
      assert DeviceFlow.suggested_vault_name("ZZZZ-ZZZZ", reader.id) == nil
    end

    test "returns nil once the code has been authorized (no longer pending)" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1", "Local")
      {:ok, _} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)
      assert DeviceFlow.suggested_vault_name(auth.user_code, user.id) == nil
    end

    test "returns nil for expired code" do
      reader = insert(:user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1", "Local")
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(da in Engram.Auth.DeviceAuthorization, where: da.id == ^auth.id),
        [set: [expires_at: past]],
        skip_tenant_check: true
      )

      assert DeviceFlow.suggested_vault_name(auth.user_code, reader.id) == nil
    end

    test "the first reader claims the code; subsequent reads by other users return nil" do
      first = insert(:user)
      second = insert(:user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1", "Sensitive Vault")

      # First user gets the name and atomically claims the row.
      assert DeviceFlow.suggested_vault_name(auth.user_code, first.id) == "Sensitive Vault"

      # Second user (e.g. someone who shoulder-surfed the code) is blocked.
      assert DeviceFlow.suggested_vault_name(auth.user_code, second.id) == nil

      # First user can re-read their own claim.
      assert DeviceFlow.suggested_vault_name(auth.user_code, first.id) == "Sensitive Vault"
    end
  end

  describe "authorize_device/3" do
    test "authorizes a pending device with user and vault" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")

      assert {:ok, updated} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)
      assert updated.status == "authorized"
      assert updated.user_id == user.id
      assert updated.vault_id == vault.id
    end

    test "rejects expired device code" do
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")

      auth
      |> Ecto.Changeset.change(%{
        expires_at: DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      })
      |> Repo.update!()

      user = insert(:user)
      vault = insert(:vault, user: user)

      assert {:error, :not_found_or_expired} =
               DeviceFlow.authorize_device(auth.user_code, user, vault.id)
    end

    test "rejects already-authorized device code" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")
      {:ok, _} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)

      assert {:error, :not_found_or_expired} =
               DeviceFlow.authorize_device(auth.user_code, user, vault.id)
    end

    test "rejects vault not owned by user" do
      user = insert(:user)
      other_user = insert(:user)
      vault = insert(:vault, user: other_user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")

      assert {:error, :vault_not_found} =
               DeviceFlow.authorize_device(auth.user_code, user, vault.id)
    end
  end

  describe "exchange_device_code/1" do
    test "returns tokens for authorized device code" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")
      {:ok, _} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)

      assert {:ok, result} = DeviceFlow.exchange_device_code(auth.device_code)
      assert is_binary(result.access_token)
      assert is_binary(result.refresh_token)
      assert String.starts_with?(result.refresh_token, "engram_rt_")
      assert result.vault_id == vault.id
      assert result.user_email == user.email
      assert result.expires_in == Engram.Token.ttl_seconds()
    end

    test "expires_in matches the actual JWT exp claim" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")
      {:ok, _} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)

      {:ok, result} = DeviceFlow.exchange_device_code(auth.device_code)
      {:ok, claims} = Engram.Token.verify_and_validate(result.access_token)

      # Compare values *inside* the JWT — `iat` is captured by the same call
      # that sets `exp`, so this is immune to scheduler delay between the
      # test capturing wall-clock time and the token actually being signed.
      jwt_ttl = claims["exp"] - claims["iat"]
      assert jwt_ttl == result.expires_in
    end

    test "marks device code as consumed after exchange" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")
      {:ok, _} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)
      {:ok, _} = DeviceFlow.exchange_device_code(auth.device_code)

      assert {:error, :expired_or_invalid} = DeviceFlow.exchange_device_code(auth.device_code)
    end

    test "returns authorization_pending for pending device code" do
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")
      assert {:error, :authorization_pending} = DeviceFlow.exchange_device_code(auth.device_code)
    end

    test "returns expired_or_invalid for unknown device code" do
      assert {:error, :expired_or_invalid} = DeviceFlow.exchange_device_code("nonexistent")
    end
  end

  describe "refresh_access_token/1" do
    test "returns new token pair and rotates refresh token" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")
      {:ok, _} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)
      {:ok, initial} = DeviceFlow.exchange_device_code(auth.device_code)

      assert {:ok, refreshed} = DeviceFlow.refresh_access_token(initial.refresh_token)
      assert is_binary(refreshed.access_token)
      assert is_binary(refreshed.refresh_token)
      assert refreshed.refresh_token != initial.refresh_token
      assert refreshed.expires_in == Engram.Token.ttl_seconds()
    end

    test "old refresh token still works within the grace window" do
      # Rotation is single-use, but a short grace window lets a client that lost
      # the rotated token (e.g. a plugin reload mid-refresh) recover instead of
      # being bricked for the token's full 90-day life.
      user = insert(:user)
      vault = insert(:vault, user: user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")
      {:ok, _} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)
      {:ok, initial} = DeviceFlow.exchange_device_code(auth.device_code)
      {:ok, _} = DeviceFlow.refresh_access_token(initial.refresh_token)

      # Immediate reuse (well within the grace window) still succeeds.
      assert {:ok, refreshed} = DeviceFlow.refresh_access_token(initial.refresh_token)
      assert is_binary(refreshed.access_token)
    end

    test "old refresh token is rejected after the grace window expires" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")
      {:ok, _} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)
      {:ok, initial} = DeviceFlow.exchange_device_code(auth.device_code)
      {:ok, _} = DeviceFlow.refresh_access_token(initial.refresh_token)

      # Age the revocation past the grace window.
      stale = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(rt in DeviceRefreshToken, where: not is_nil(rt.revoked_at)),
        [set: [revoked_at: stale]],
        skip_tenant_check: true
      )

      assert {:error, :invalid_refresh_token} =
               DeviceFlow.refresh_access_token(initial.refresh_token)
    end

    test "rejects unknown refresh token" do
      assert {:error, :invalid_refresh_token} = DeviceFlow.refresh_access_token("engram_rt_fake")
    end

    test "rotation keeps the new token in the same family" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")
      {:ok, _} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)
      {:ok, initial} = DeviceFlow.exchange_device_code(auth.device_code)
      {:ok, _} = DeviceFlow.refresh_access_token(initial.refresh_token)

      families =
        Repo.all(from(rt in DeviceRefreshToken, select: rt.family_id), skip_tenant_check: true)

      assert length(families) == 2
      assert length(Enum.uniq(families)) == 1
    end

    test "a fresh login starts a distinct family" do
      user = insert(:user)
      vault = insert(:vault, user: user)

      {:ok, a} = DeviceFlow.start_device_flow("client_1")
      {:ok, _} = DeviceFlow.authorize_device(a.user_code, user, vault.id)
      {:ok, _} = DeviceFlow.exchange_device_code(a.device_code)

      {:ok, b} = DeviceFlow.start_device_flow("client_1")
      {:ok, _} = DeviceFlow.authorize_device(b.user_code, user, vault.id)
      {:ok, _} = DeviceFlow.exchange_device_code(b.device_code)

      families =
        Repo.all(from(rt in DeviceRefreshToken, select: rt.family_id), skip_tenant_check: true)

      assert length(Enum.uniq(families)) == 2
    end

    test "reuse outside the leeway revokes the entire token family" do
      # The security-defining case (RFC 9700 §4.14.2): replaying a rotated token
      # after the leeway is treated as a breach. The whole family is invalidated,
      # so even the *current, still-valid* token is rejected and the user must
      # re-authenticate.
      user = insert(:user)
      vault = insert(:vault, user: user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")
      {:ok, _} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)
      {:ok, initial} = DeviceFlow.exchange_device_code(auth.device_code)

      # initial -> current, both in the same family.
      {:ok, current} = DeviceFlow.refresh_access_token(initial.refresh_token)

      # Age the old token's revocation past the leeway so its replay is a breach.
      stale = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(rt in DeviceRefreshToken, where: not is_nil(rt.revoked_at)),
        [set: [revoked_at: stale]],
        skip_tenant_check: true
      )

      assert {:error, :invalid_refresh_token} =
               DeviceFlow.refresh_access_token(initial.refresh_token)

      # Family nuked: the current valid token no longer works.
      assert {:error, :invalid_refresh_token} =
               DeviceFlow.refresh_access_token(current.refresh_token)
    end

    test "a breach only revokes the offending family, not other families" do
      user = insert(:user)
      vault = insert(:vault, user: user)

      # Family A: rotate then breach.
      {:ok, a} = DeviceFlow.start_device_flow("client_1")
      {:ok, _} = DeviceFlow.authorize_device(a.user_code, user, vault.id)
      {:ok, a0} = DeviceFlow.exchange_device_code(a.device_code)
      {:ok, _a1} = DeviceFlow.refresh_access_token(a0.refresh_token)

      # Family B: independent, healthy login.
      {:ok, b} = DeviceFlow.start_device_flow("client_1")
      {:ok, _} = DeviceFlow.authorize_device(b.user_code, user, vault.id)
      {:ok, b0} = DeviceFlow.exchange_device_code(b.device_code)

      stale = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(rt in DeviceRefreshToken, where: not is_nil(rt.revoked_at)),
        [set: [revoked_at: stale]],
        skip_tenant_check: true
      )

      # Breach family A.
      assert {:error, :invalid_refresh_token} = DeviceFlow.refresh_access_token(a0.refresh_token)

      # Family B is untouched.
      assert {:ok, _} = DeviceFlow.refresh_access_token(b0.refresh_token)
    end

    test "an expired token is rejected and never triggers family revocation" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")
      {:ok, _} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)
      {:ok, initial} = DeviceFlow.exchange_device_code(auth.device_code)
      {:ok, current} = DeviceFlow.refresh_access_token(initial.refresh_token)

      # Expire the whole family.
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(rt in DeviceRefreshToken),
        [set: [expires_at: past]],
        skip_tenant_check: true
      )

      assert {:error, :invalid_refresh_token} =
               DeviceFlow.refresh_access_token(current.refresh_token)
    end
  end

  describe "plugin_connected onboarding hook" do
    test "records plugin_connected on successful exchange" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      {:ok, auth} = DeviceFlow.start_device_flow("plugin")
      {:ok, _} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)

      {:ok, _tokens} = DeviceFlow.exchange_device_code(auth.device_code)

      assert "plugin_connected" in Engram.Onboarding.list_actions(user.id)
    end
  end

  describe "cleanup_expired/0" do
    test "deletes expired device authorizations" do
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")

      auth
      |> Ecto.Changeset.change(%{
        expires_at:
          DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)
      })
      |> Repo.update!()

      {deleted, _} = DeviceFlow.cleanup_expired()
      assert deleted >= 1
    end
  end
end
