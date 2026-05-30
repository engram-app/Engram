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
        revoked_at: DateTime.utc_now(:second)
      )

      assert Connections.count_active(user.id, :mcp) == 1
      assert Connections.count_active(user.id, :obsidian) == 1
    end

    test "two simultaneously active tokens for same client collapse to 1 (DISTINCT)" do
      user = insert_user()
      client = insert(:oauth_client, kind: "mcp")
      family = Ecto.UUID.generate()

      # Both tokens are active (revoked_at: nil, consumed_at: nil). Without
      # DISTINCT client_id in the query this would return 2 — the DISTINCT is
      # the load-bearing assertion here.
      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        family_id: family
      )

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        family_id: family
      )

      assert Connections.count_active(user.id, :mcp) == 1
    end

    test "consumed and revoked tokens are excluded from active count" do
      user = insert_user()
      client = insert(:oauth_client, kind: "mcp")
      now = DateTime.utc_now(:second)

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        consumed_at: now
      )

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        revoked_at: now
      )

      assert Connections.count_active(user.id, :mcp) == 0
    end
  end

  describe "list_for_user/1" do
    test "returns oauth connections grouped by client_id with logo info" do
      user = insert_user()
      vault = insert(:vault, user: user)

      client =
        insert(:oauth_client,
          kind: "mcp",
          software_id: "anthropic-claude-desktop",
          client_name: "Claude Desktop"
        )

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: vault.id
      )

      assert [
               %{
                 kind: :mcp,
                 client_id: cid,
                 name: "Claude Desktop",
                 verified: true,
                 vault_id: vid
               }
             ] =
               Connections.list_for_user(user.id)

      assert cid == client.client_id
      assert vid == vault.id
    end

    test "includes PATs as kind=:pat" do
      user = insert_user()
      insert(:api_key, user: user, name: "my-script")

      assert [%{kind: :pat, name: "my-script", client_id: nil, key_id: kid, redirect_uris: []}] =
               Connections.list_for_user(user.id)

      assert is_integer(kid)
    end

    test "orders connections most-recently-used first" do
      user = insert_user()
      client_a = insert(:oauth_client, kind: "mcp", client_name: "A")
      client_b = insert(:oauth_client, kind: "mcp", client_name: "B")
      older = ~U[2026-01-01 00:00:00Z]
      newer = ~U[2026-05-30 00:00:00Z]

      # client_a older, client_b newer — B should sort first regardless of alphabetic order
      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client_a.client_id,
        last_used_at: older
      )

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client_b.client_id,
        last_used_at: newer
      )

      rows = Connections.list_for_user(user.id)
      names = Enum.map(rows, & &1.name)
      assert names == ["B", "A"]
    end

    test "excludes revoked oauth grants" do
      user = insert_user()
      client = insert(:oauth_client, kind: "mcp")
      now = DateTime.utc_now(:second)

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        revoked_at: now
      )

      assert Connections.list_for_user(user.id) == []
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

      assert {:error, :not_found} =
               Connections.revoke_oauth_family(user.id, stranger_client_id, nil)
    end
  end
end
