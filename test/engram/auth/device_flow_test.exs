defmodule Engram.Auth.DeviceFlowTest do
  use Engram.DataCase, async: true

  alias Engram.Auth.DeviceFlow

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

    test "old refresh token is revoked after rotation" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")
      {:ok, _} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)
      {:ok, initial} = DeviceFlow.exchange_device_code(auth.device_code)
      {:ok, _} = DeviceFlow.refresh_access_token(initial.refresh_token)

      assert {:error, :invalid_refresh_token} =
               DeviceFlow.refresh_access_token(initial.refresh_token)
    end

    test "rejects unknown refresh token" do
      assert {:error, :invalid_refresh_token} = DeviceFlow.refresh_access_token("engram_rt_fake")
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
