defmodule EngramWeb.SyncChannelTest do
  use EngramWeb.ChannelCase, async: true

  setup do
    user = insert(:user)
    other_user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, other_user} = Engram.Crypto.ensure_user_dek(other_user)
    vault = insert(:vault, user: user, is_default: true)
    socket = user_socket(user)
    {:ok, _, socket} = join_sync(socket, user, vault)

    %{socket: socket, user: user, vault: vault, other_user: other_user}
  end

  # ---------------------------------------------------------------------------
  # Connection & auth
  # ---------------------------------------------------------------------------

  describe "connect/3" do
    test "accepts valid API key" do
      user = insert(:user)
      {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test")

      assert {:ok, socket} =
               connect(EngramWeb.UserSocket, %{"token" => api_key})

      assert socket.assigns.current_user.id == user.id
    end

    test "rejects missing token" do
      assert :error = connect(EngramWeb.UserSocket, %{})
    end

    test "rejects invalid token" do
      assert :error = connect(EngramWeb.UserSocket, %{"token" => "bad_token"})
    end
  end

  describe "join/3" do
    test "join reply advertises the reconnect jitter window", %{user: user, vault: vault} do
      socket = user_socket(user)
      assert {:ok, reply, _socket} = join_sync(socket, user, vault)
      assert reply.reconnect_jitter_max_ms == 5_000
    end

    test "accepts join for own user_id and vault", %{user: user, vault: vault} do
      socket = user_socket(user)
      assert {:ok, _, _} = join_sync(socket, user, vault)
    end

    test "rejects join for another user's channel", %{user: user, other_user: other_user} do
      other_vault = insert(:vault, user: other_user, is_default: true)
      socket = user_socket(user)

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 EngramWeb.SyncChannel,
                 "sync:#{other_user.id}:#{other_vault.id}"
               )
    end

    test "rejects join for vault belonging to another user", %{user: user, other_user: other_user} do
      other_vault = insert(:vault, user: other_user, is_default: true)
      socket = user_socket(user)

      assert {:error, %{reason: "vault_not_found"}} =
               subscribe_and_join(
                 socket,
                 EngramWeb.SyncChannel,
                 "sync:#{user.id}:#{other_vault.id}"
               )
    end

    test "rejects join with invalid vault_id", %{user: user} do
      socket = user_socket(user)

      assert {:error, %{reason: "invalid_vault_id"}} =
               subscribe_and_join(socket, EngramWeb.SyncChannel, "sync:#{user.id}:notanint")
    end

    test "rejects topic without vault_id", %{user: user} do
      socket = user_socket(user)

      assert {:error, %{reason: "invalid_topic"}} =
               subscribe_and_join(socket, EngramWeb.SyncChannel, "sync:#{user.id}")
    end
  end

  # ---------------------------------------------------------------------------
  # API key vault restrictions on join
  # ---------------------------------------------------------------------------

  describe "join/3 with restricted API key" do
    test "restricted key can join its authorized vault", %{user: user, vault: vault} do
      {:ok, _raw, api_key_record} = Engram.Accounts.create_api_key(user, "restricted-chan")

      Engram.Repo.insert_all("api_key_vaults", [
        %{api_key_id: Ecto.UUID.dump!(api_key_record.id), vault_id: Ecto.UUID.dump!(vault.id)}
      ])

      socket = user_socket(user, api_key_record)
      assert {:ok, _, _} = join_sync(socket, user, vault)
    end

    test "restricted key cannot join unauthorized vault", %{user: user, vault: vault} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
      {:ok, vault_b} = Engram.Vaults.create_vault(user, %{name: "Vault B"})
      {:ok, _raw, api_key_record} = Engram.Accounts.create_api_key(user, "restricted-chan2")

      # Only grant access to vault_b — NOT the default vault
      Engram.Repo.insert_all("api_key_vaults", [
        %{api_key_id: Ecto.UUID.dump!(api_key_record.id), vault_id: Ecto.UUID.dump!(vault_b.id)}
      ])

      # Try to join the default vault (which the key does NOT have access to)
      socket = user_socket(user, api_key_record)

      assert {:error, %{reason: "api_key_vault_forbidden"}} =
               subscribe_and_join(
                 socket,
                 EngramWeb.SyncChannel,
                 "sync:#{user.id}:#{vault.id}"
               )
    end

    test "restricted key on topic without vault_id gets invalid_topic", %{user: user} do
      {:ok, _raw, api_key_record} = Engram.Accounts.create_api_key(user, "restricted-compat")
      socket = user_socket(user, api_key_record)

      assert {:error, %{reason: "invalid_topic"}} =
               subscribe_and_join(socket, EngramWeb.SyncChannel, "sync:#{user.id}")
    end

    test "unrestricted key (no api_key_vaults rows) can join any vault", %{
      user: user,
      vault: vault
    } do
      {:ok, _raw, api_key_record} = Engram.Accounts.create_api_key(user, "unrestricted-chan")

      socket = user_socket(user, api_key_record)
      assert {:ok, _, _} = join_sync(socket, user, vault)
    end
  end

  # ---------------------------------------------------------------------------
  # Batch broadcasts (notes.batch / folders.batch) pass through unintercepted
  # ---------------------------------------------------------------------------

  describe "batch broadcasts pass through" do
    test "notes.batch reaches subscribed client", %{user: user, vault: vault} do
      EngramWeb.Endpoint.broadcast!(
        "sync:#{user.id}:#{vault.id}",
        "notes.batch",
        %{op: "delete", ids: [1, 2, 3]}
      )

      assert_push "notes.batch", %{op: "delete", ids: [1, 2, 3]}
    end

    test "folders.batch reaches subscribed client", %{user: user, vault: vault} do
      EngramWeb.Endpoint.broadcast!(
        "sync:#{user.id}:#{vault.id}",
        "folders.batch",
        %{op: "move", ids: [42], target_parent_id: 99}
      )

      assert_push "folders.batch", %{op: "move", ids: [42], target_parent_id: 99}
    end
  end
end
