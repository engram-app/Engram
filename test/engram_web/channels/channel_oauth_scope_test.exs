defmodule EngramWeb.ChannelOAuthScopeTest do
  @moduledoc """
  A vault-scoped OAuth grant must bind the WebSocket path, not just HTTP.

  Plugs do not run for a socket connect, so `OAuthScopeEnforce` never fires
  here — before this the channels checked only the API key's vault access and
  a token granted vault A joined vault B's `sync:`/`crdt:` topic, which is the
  live note-sync path streaming document content.

  Every socket here comes through the real `UserSocket.connect/3` with a real
  minted token: the scope must be derived from the VERIFIED token, so a test
  that hand-assigns it would prove nothing.
  """
  use EngramWeb.ChannelCase, async: false

  alias Engram.{Accounts, Crypto, Vaults}

  setup do
    # `external_id` is what the token's `sub` carries; without it the local
    # auth provider rejects our minted token as :missing_claims before any of
    # this is reachable. Same helper shape as the Task 7a plug test.
    user = insert(:user, external_id: "test-#{Ecto.UUID.generate()}")
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, granted, _} = Vaults.register_vault(user, "granted", Ecto.UUID.generate())
    {:ok, ungranted, _} = Vaults.register_vault(user, "ungranted", Ecto.UUID.generate())

    %{user: user, granted: granted, ungranted: ungranted}
  end

  # Mints the same claim shape `Engram.OAuth.issue_access_token/3` mints and
  # connects with it. `vault_ids: nil` is the unrestricted grant.
  defp oauth_socket(user, vault_ids) do
    extras = %{"scope" => "notes:read notes:write"}
    extras = if vault_ids, do: Map.put(extras, "vault_ids", vault_ids), else: extras

    {:ok, socket} =
      connect(EngramWeb.UserSocket, %{"token" => Accounts.generate_jwt(user, extras)})

    socket
  end

  defp join_sync_topic(socket, user, vault),
    do: subscribe_and_join(socket, EngramWeb.SyncChannel, "sync:#{user.id}:#{vault.id}")

  defp join_crdt_topic(socket, user, vault) do
    subscribe_and_join(socket, EngramWeb.CrdtChannel, "crdt:#{user.id}:#{vault.id}", %{
      "crdt_proto" => 2
    })
  end

  describe "sync: topic" do
    test "a granted vault joins", %{user: user, granted: granted} do
      assert {:ok, _, _} = user |> oauth_socket([granted.id]) |> join_sync_topic(user, granted)
    end

    test "a vault outside the grant is refused", %{
      user: user,
      granted: granted,
      ungranted: ungranted
    } do
      assert {:error, %{reason: "api_key_vault_forbidden"}} =
               user |> oauth_socket([granted.id]) |> join_sync_topic(user, ungranted)
    end

    test "an unscoped token joins anything", %{user: user, granted: granted, ungranted: ungranted} do
      assert {:ok, _, _} = user |> oauth_socket(nil) |> join_sync_topic(user, granted)
      assert {:ok, _, _} = user |> oauth_socket(nil) |> join_sync_topic(user, ungranted)
    end
  end

  describe "crdt: topic" do
    test "a granted vault joins", %{user: user, granted: granted} do
      assert {:ok, _, _} = user |> oauth_socket([granted.id]) |> join_crdt_topic(user, granted)
    end

    test "a vault outside the grant is refused", %{
      user: user,
      granted: granted,
      ungranted: ungranted
    } do
      assert {:error, %{reason: "api_key_vault_forbidden"}} =
               user |> oauth_socket([granted.id]) |> join_crdt_topic(user, ungranted)
    end

    test "an unscoped token joins anything", %{user: user, granted: granted, ungranted: ungranted} do
      assert {:ok, _, _} = user |> oauth_socket(nil) |> join_crdt_topic(user, granted)
      assert {:ok, _, _} = user |> oauth_socket(nil) |> join_crdt_topic(user, ungranted)
    end
  end

  # A multi-vault grant is the shape the scalar `vault_id` claim cannot
  # express; both members must join and a third vault must still be refused.
  test "a multi-vault grant admits every listed vault and nothing else", %{
    user: user,
    granted: granted,
    ungranted: ungranted
  } do
    {:ok, third, _} = Vaults.register_vault(user, "third", Ecto.UUID.generate())
    socket = oauth_socket(user, [granted.id, ungranted.id])

    assert {:ok, _, _} = join_sync_topic(socket, user, granted)
    assert {:ok, _, _} = join_sync_topic(socket, user, ungranted)

    assert {:error, %{reason: "api_key_vault_forbidden"}} =
             join_sync_topic(socket, user, third)
  end
end
