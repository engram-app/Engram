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

    test "count_active(:obsidian) counts device_refresh_token families" do
      user = insert_user()
      vault = insert(:vault, user: user)
      family = Ecto.UUID.generate()

      # Two tokens in the same family — should collapse to 1
      insert(:device_refresh_token, user: user, vault: vault, family_id: family)
      insert(:device_refresh_token, user: user, vault: vault, family_id: family)

      assert Connections.count_active(user.id, :obsidian) == 1
    end

    test "count_active(:obsidian) sums oauth obsidian + device families" do
      user = insert_user()
      vault = insert(:vault, user: user)
      obs_client = insert(:oauth_client, kind: "obsidian")
      insert(:oauth_refresh_token, user_id: user.id, client_id: obs_client.client_id)
      insert(:device_refresh_token, user: user, vault: vault)

      # 1 oauth obsidian family + 1 device family = 2
      assert Connections.count_active(user.id, :obsidian) == 2
    end

    test "count_active(:obsidian) excludes revoked device tokens" do
      user = insert_user()
      vault = insert(:vault, user: user)
      now = DateTime.utc_now(:second)
      insert(:device_refresh_token, user: user, vault: vault, revoked_at: now)

      assert Connections.count_active(user.id, :obsidian) == 0
    end

    test "count_active(:obsidian) excludes expired device tokens" do
      user = insert_user()
      vault = insert(:vault, user: user)

      expired_at =
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      insert(:device_refresh_token, user: user, vault: vault, expires_at: expired_at)

      assert Connections.count_active(user.id, :obsidian) == 0
    end

    test "count_active(:mcp) does not count device tokens" do
      user = insert_user()
      vault = insert(:vault, user: user)
      insert(:device_refresh_token, user: user, vault: vault)

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
               Connections.list_for_user(user)

      assert cid == client.client_id
      assert vid == vault.id
    end

    test "identifies claude.ai connector by redirect host" do
      user = insert_user()

      client =
        insert(:oauth_client,
          kind: "mcp",
          software_id: nil,
          client_name: "Claude",
          redirect_uris: ["https://claude.ai/api/mcp/auth_callback"]
        )

      insert(:oauth_refresh_token, user_id: user.id, client_id: client.client_id)

      assert [
               %{
                 kind: :mcp,
                 name: "Claude",
                 verified: true,
                 slug: "claude",
                 logo: "/assets/clients/claude.svg"
               }
             ] = Connections.list_for_user(user)
    end

    test "includes PATs as kind=:pat" do
      user = insert_user()
      insert(:api_key, user: user, name: "my-script")

      assert [%{kind: :pat, name: "my-script", client_id: nil, key_id: kid, redirect_uris: []}] =
               Connections.list_for_user(user)

      assert is_binary(kid)
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

      rows = Connections.list_for_user(user)
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

      assert Connections.list_for_user(user) == []
    end

    test "includes device refresh token families as kind=:obsidian" do
      user = insert_user()
      vault = insert(:vault, user: user)
      family_id = Ecto.UUID.generate()
      insert(:device_refresh_token, user: user, vault: vault, family_id: family_id)

      rows = Connections.list_for_user(user)
      assert [row] = rows

      assert row.kind == :obsidian
      assert row.client_id == family_id
      assert row.name == "Obsidian Vault Sync"
      assert row.software_id == "engram-vault-sync"
      assert row.verified == true
      assert row.logo == "/assets/clients/engram-vault-sync.svg"
      assert row.vault_id == vault.id
      assert row.key_id == nil
      assert row.redirect_uris == []
    end

    test "device rows: multiple tokens in one family surface as a single connection" do
      user = insert_user()
      vault = insert(:vault, user: user)
      family_id = Ecto.UUID.generate()

      insert(:device_refresh_token, user: user, vault: vault, family_id: family_id)
      insert(:device_refresh_token, user: user, vault: vault, family_id: family_id)

      rows = Connections.list_for_user(user)
      assert length(rows) == 1
    end

    test "device rows: excludes revoked device tokens from listing" do
      user = insert_user()
      vault = insert(:vault, user: user)
      now = DateTime.utc_now(:second)
      insert(:device_refresh_token, user: user, vault: vault, revoked_at: now)

      assert Connections.list_for_user(user) == []
    end

    test "device rows: excludes expired device tokens from listing" do
      user = insert_user()
      vault = insert(:vault, user: user)

      expired_at =
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      insert(:device_refresh_token, user: user, vault: vault, expires_at: expired_at)

      assert Connections.list_for_user(user) == []
    end

    test "vault_name resolves to the decrypted vault name" do
      user = insert_user()
      # create_vault drives the real encryption pipeline so list_vaults/1 can
      # decrypt the name back. The factory-built :vault has random ciphertext
      # which would decrypt to nil — that's the "vault gone" path tested below.
      {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Personal"})
      client = insert(:oauth_client, kind: "mcp")

      insert(:oauth_refresh_token,
        user_id: user.id,
        vault_id: vault.id,
        client_id: client.client_id
      )

      [row] = Connections.list_for_user(user)
      assert row.vault_id == vault.id
      assert row.vault_name == "Personal"
    end

    test "vault_name is nil when the connection references an unknown vault" do
      user = insert_user()
      client = insert(:oauth_client, kind: "mcp")

      # Factory inserts a vault row but its ciphertext is random, so
      # Vaults.list_vaults logs a decrypt failure + returns the vault without
      # a :name. The merge step then yields vault_name: nil — the same shape
      # the frontend sees when a vault was soft-deleted between the grant and
      # the page render.
      stale = insert(:vault, user: user)

      insert(:oauth_refresh_token,
        user_id: user.id,
        vault_id: stale.id,
        client_id: client.client_id
      )

      [row] = Connections.list_for_user(user)
      assert row.vault_id == stale.id
      assert row.vault_name == nil
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

  describe "revoke_device_family/2" do
    test "sets revoked_at on all active tokens for (user, family)" do
      user = insert_user()
      vault = insert(:vault, user: user)
      family_id = Ecto.UUID.generate()

      insert(:device_refresh_token, user: user, vault: vault, family_id: family_id)
      insert(:device_refresh_token, user: user, vault: vault, family_id: family_id)

      assert :ok = Connections.revoke_device_family(user.id, family_id)
      assert Connections.count_active(user.id, :obsidian) == 0
    end

    test "is idempotent — second revoke returns :ok" do
      user = insert_user()
      vault = insert(:vault, user: user)
      family_id = Ecto.UUID.generate()
      insert(:device_refresh_token, user: user, vault: vault, family_id: family_id)

      assert :ok = Connections.revoke_device_family(user.id, family_id)
      assert :ok = Connections.revoke_device_family(user.id, family_id)
    end

    test "returns :not_found for a family the user does not own" do
      user = insert_user()
      foreign_family_id = Ecto.UUID.generate()

      assert {:error, :not_found} =
               Connections.revoke_device_family(user.id, foreign_family_id)
    end

    test "does not revoke another user's same family_id" do
      user = insert_user()
      other = insert_user()
      vault = insert(:vault, user: other)
      family_id = Ecto.UUID.generate()

      insert(:device_refresh_token, user: other, vault: vault, family_id: family_id)

      # Revoking for `user` must fail since the family belongs to `other`
      assert {:error, :not_found} = Connections.revoke_device_family(user.id, family_id)
      # And other user's connection is still active
      assert Connections.count_active(other.id, :obsidian) == 1
    end
  end
end
