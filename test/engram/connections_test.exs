defmodule Engram.ConnectionsTest do
  use Engram.DataCase, async: true
  import Engram.Factory
  alias Engram.Connections

  describe "count_active/2" do
    test "counts only active refresh-token families for given kind" do
      user = insert_user()
      mcp_client = insert(:oauth_client, kind: "mcp")
      obs_client = insert(:oauth_client, kind: "obsidian")

      insert(:oauth_refresh_token, user_id: user.id, client_id: mcp_client.client_id)
      insert(:oauth_refresh_token, user_id: user.id, client_id: obs_client.client_id)

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: mcp_client.client_id,
        revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      assert Connections.count_active(user.id, :mcp) == 1
      assert Connections.count_active(user.id, :obsidian) == 1
    end

    test "two active refresh tokens for same client count as one connection" do
      user = insert_user()
      client = insert(:oauth_client, kind: "mcp")
      family = Ecto.UUID.generate()

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        family_id: family
      )

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        family_id: family,
        consumed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      assert Connections.count_active(user.id, :mcp) == 1
    end
  end

  describe "revoke_oauth_family/3" do
    test "sets revoked_at on all rows for (user, client, vault)" do
      user = insert_user()
      vault = insert(:vault, user: user)
      client = insert(:oauth_client, kind: "mcp")

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: vault.id
      )

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: vault.id
      )

      assert :ok = Connections.revoke_oauth_family(user.id, client.client_id, vault.id)
      assert Connections.count_active(user.id, :mcp) == 0
    end

    test "is idempotent" do
      user = insert_user()
      vault = insert(:vault, user: user)
      client = insert(:oauth_client, kind: "mcp")

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: vault.id
      )

      assert :ok = Connections.revoke_oauth_family(user.id, client.client_id, vault.id)
      assert :ok = Connections.revoke_oauth_family(user.id, client.client_id, vault.id)
    end

    test "returns :not_found for foreign client" do
      user = insert_user()
      stranger_client_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Connections.revoke_oauth_family(user.id, stranger_client_id, nil)
    end
  end
end
