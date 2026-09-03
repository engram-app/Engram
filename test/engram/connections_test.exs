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
      # DISTINCT client_id in the query this would return 2, the DISTINCT is
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

      # Two tokens in the same family, should collapse to 1
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

      # That software_id is a SPOOF, not a real Claude Desktop registration:
      # the key was deleted in #1156 and real Claude Desktop is attributed by
      # its claude.ai redirect host (see the next test). Kept here precisely to
      # pin that the rogue claim yields no vendor identity.

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: vault.id
      )

      # `name` here is the raw self-reported client_name falling through
      # (`identity.display_name || c.client_name`), NOT resolved identity:
      # logo/slug/display_name are all nil, so the UI badges this as an
      # unverified client rather than rendering Anthropic's logo.
      assert [
               %{
                 kind: :mcp,
                 client_id: cid,
                 name: "Claude Desktop",
                 verified: false,
                 logo: nil,
                 slug: nil,
                 vault_ids: vids
               }
             ] =
               Connections.list_for_user(user)

      assert cid == client.client_id
      assert vids == [vault.id]
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

      # The grant's OWN redirect, not the client's registered list — that is
      # what carries the badge since #1204.
      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        redirect_uri: "https://claude.ai/api/mcp/auth_callback"
      )

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

    # THE #1204 regression, end to end. DCR is public, so an attacker registers
    # a loopback alongside Anthropic's real callback, authorizes with the
    # loopback, and takes delivery of the code on their own machine. Before the
    # fix the connections list scanned the REGISTERED list and found claude.ai,
    # so the rogue grant rendered as Claude, verified, with Anthropic's logo —
    # exactly the row a user reviewing their connections would leave alone.
    test "a grant delivered to loopback is unverified even if the client also registered claude.ai" do
      user = insert_user()

      client =
        insert(:oauth_client,
          kind: "mcp",
          software_id: nil,
          client_name: "Claude",
          redirect_uris: [
            "http://localhost:9999/steal",
            "https://claude.ai/api/mcp/auth_callback"
          ]
        )

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        redirect_uri: "http://localhost:9999/steal"
      )

      assert [%{name: "Claude", verified: false, logo: nil}] = Connections.list_for_user(user)
    end

    # Grants issued before the column existed have no recorded redirect and the
    # evidence is unrecoverable (auth codes are single-use). Fail closed: the
    # user sees an unverified row rather than a badge we cannot justify.
    test "a grant with no recorded redirect is unverified" do
      user = insert_user()

      client =
        insert(:oauth_client,
          kind: "mcp",
          software_id: nil,
          client_name: "Claude",
          redirect_uris: ["https://claude.ai/api/mcp/auth_callback"]
        )

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        redirect_uri: nil
      )

      assert [%{verified: false, logo: nil}] = Connections.list_for_user(user)
    end

    # Regression: Claude Code redirects to loopback, which is un-verifiable by
    # design, so it resolved to slug: nil and the onboarding checklist row for
    # it could never tick. The slug must survive to the view while `verified`
    # and `logo` stay off, the name is self-asserted.
    test "attributes a loopback client to its slug via client_name, unverified" do
      user = insert_user()

      client =
        insert(:oauth_client,
          kind: "mcp",
          software_id: nil,
          client_name: "Claude Code (engram)",
          redirect_uris: ["http://localhost:62184/callback"]
        )

      insert(:oauth_refresh_token, user_id: user.id, client_id: client.client_id)

      assert [
               %{
                 kind: :mcp,
                 name: "Claude Code (engram)",
                 verified: false,
                 slug: "claude_code",
                 logo: nil
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

      # client_a older, client_b newer, B should sort first regardless of alphabetic order
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
      assert row.vault_ids == [vault.id]
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

    test "vault_names resolves to the decrypted vault name" do
      user = insert_user()
      # register_vault drives the real encryption pipeline so list_vaults/1 can
      # decrypt the name back. The factory-built :vault has random ciphertext
      # which would decrypt to nil, that's the "vault gone" path tested below.
      {:ok, vault, _} = Engram.Vaults.register_vault(user, "Personal", Ecto.UUID.generate())
      client = insert(:oauth_client, kind: "mcp")

      insert(:oauth_refresh_token,
        user_id: user.id,
        vault_id: vault.id,
        client_id: client.client_id
      )

      [row] = Connections.list_for_user(user)
      assert row.vault_ids == [vault.id]
      assert row.vault_names == ["Personal"]
    end

    test "vault_names entry is nil when the connection references an unknown vault" do
      user = insert_user()
      client = insert(:oauth_client, kind: "mcp")

      # Factory inserts a vault row but its ciphertext is random, so
      # Vaults.list_vaults logs a decrypt failure + returns the vault without
      # a :name. The merge step then yields a nil entry, the same shape
      # the frontend sees when a vault was soft-deleted between the grant and
      # the page render.
      stale = insert(:vault, user: user)

      insert(:oauth_refresh_token,
        user_id: user.id,
        vault_id: stale.id,
        client_id: client.client_id
      )

      [row] = Connections.list_for_user(user)
      assert row.vault_ids == [stale.id]
      assert row.vault_names == [nil]
    end

    # `client_name` is the CLIENT's own name and is identical across two grants
    # for the same client — the exact case a user-typed label exists to
    # disambiguate, so it wins.
    test "prefers the user's label over the client name" do
      user = insert_user()
      client = insert(:oauth_client, kind: "mcp", client_name: "Claude Desktop")

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        label: "My laptop"
      )

      assert [%{name: "My laptop"}] = Connections.list_for_user(user)
    end

    test "an unlabelled grant still falls back to the client identity" do
      user = insert_user()
      client = insert(:oauth_client, kind: "mcp", client_name: "Claude Desktop")

      insert(:oauth_refresh_token, user_id: user.id, client_id: client.client_id)

      assert [listed] = Connections.list_for_user(user)
      assert listed.name == "Claude Desktop"
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

  describe "revoke_oauth_grant/2" do
    test "revokes ONE grant and leaves the client's other grant intact" do
      # The defect this pins: both grants belong to one client, so a
      # client-wide revoke kills a connection the user never clicked.
      %{user: user, work: work, personal: personal, work_family: work_family} =
        two_grants_one_client()

      assert :ok = Connections.revoke_oauth_grant(user.id, work_family)

      assert [survivor] = Connections.list_for_user(user)
      refute survivor.family_id == work_family
      assert survivor.vault_ids == [personal.id]

      # And the revoked one is really dead, not merely hidden from the list.
      assert [revoked] =
               Engram.Repo.all(
                 from(t in Engram.OAuth.RefreshToken, where: t.family_id == ^work_family)
               )

      assert revoked.revoked_at
      assert revoked.vault_ids == [work.id]
    end

    test "revokes every token in the family, including rotation successors" do
      user = insert_user()
      client = insert(:oauth_client, kind: "mcp")
      family = Ecto.UUID.generate()

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        family_id: family,
        consumed_at: DateTime.utc_now(:second)
      )

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        family_id: family
      )

      assert :ok = Connections.revoke_oauth_grant(user.id, family)
      assert Connections.count_active(user.id, :mcp) == 0

      assert Enum.all?(
               Engram.Repo.all(
                 from(t in Engram.OAuth.RefreshToken, where: t.family_id == ^family)
               ),
               & &1.revoked_at
             )
    end

    test "is idempotent, second revoke returns :ok" do
      %{user: user, work_family: work_family} = two_grants_one_client()

      assert :ok = Connections.revoke_oauth_grant(user.id, work_family)
      assert :ok = Connections.revoke_oauth_grant(user.id, work_family)
    end

    test "returns :not_found for a family the user does not own" do
      %{work_family: work_family} = two_grants_one_client()
      stranger = insert_user()

      assert {:error, :not_found} = Connections.revoke_oauth_grant(stranger.id, work_family)

      assert {:error, :not_found} =
               Connections.revoke_oauth_grant(stranger.id, Ecto.UUID.generate())
    end

    test "the client-wide revoke still takes BOTH grants" do
      # Kept reachable on purpose: the connection cap counts clients, so
      # freeing a slot means disconnecting the app, not one of its grants.
      %{user: user, client: client} = two_grants_one_client()

      assert :ok = Connections.revoke_oauth_family(user.id, client.client_id, nil)
      assert Connections.list_for_user(user) == []
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

    test "is idempotent, second revoke returns :ok" do
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

  describe "revoke_by_vault/2" do
    test "revokes all active OAuth tokens scoped to the vault" do
      user = insert_user()
      vault = insert(:vault, user: user)
      other_vault = insert(:vault, user: user)
      client = insert(:oauth_client, kind: "mcp")

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: vault.id
      )

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: other_vault.id
      )

      assert :ok = Connections.revoke_by_vault(user.id, vault.id)

      # The other-vault token must survive
      assert Connections.count_active(user.id, :mcp) == 1
    end

    test "revokes all active device tokens scoped to the vault" do
      user = insert_user()
      vault = insert(:vault, user: user)
      other_vault = insert(:vault, user: user)

      family1 = Ecto.UUID.generate()
      family2 = Ecto.UUID.generate()
      insert(:device_refresh_token, user: user, vault: vault, family_id: family1)
      insert(:device_refresh_token, user: user, vault: other_vault, family_id: family2)

      assert :ok = Connections.revoke_by_vault(user.id, vault.id)

      # The other-vault device token must survive
      assert Connections.count_active(user.id, :obsidian) == 1
    end

    test "does not touch tokens belonging to a different user" do
      user = insert_user()
      other = insert_user()
      vault = insert(:vault, user: other)
      client = insert(:oauth_client, kind: "mcp")

      insert(:oauth_refresh_token,
        user_id: other.id,
        client_id: client.client_id,
        vault_id: vault.id
      )

      insert(:device_refresh_token, user: other, vault: vault)

      assert :ok = Connections.revoke_by_vault(user.id, vault.id)

      # other user's connections must be untouched
      assert Connections.count_active(other.id, :mcp) == 1
      assert Connections.count_active(other.id, :obsidian) == 1
    end

    test "is idempotent, second call on already-revoked vault returns :ok" do
      user = insert_user()
      vault = insert(:vault, user: user)
      client = insert(:oauth_client, kind: "mcp")

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: vault.id
      )

      assert :ok = Connections.revoke_by_vault(user.id, vault.id)
      assert :ok = Connections.revoke_by_vault(user.id, vault.id)
    end

    test "returns :ok and revokes nothing for a vault with no tokens" do
      user = insert_user()
      vault = insert(:vault, user: user)

      assert :ok = Connections.revoke_by_vault(user.id, vault.id)
    end

    test "leaves OAuth grants with no vault binding (vault_id: nil) untouched" do
      # vault_id is cast-only on OAuth refresh tokens (not required), so a grant
      # can have nil binding. Such a grant is NOT scoped to any vault, it shows
      # on the connections page with vault_id: nil, independent of any vault.
      # Deleting a vault must not collaterally revoke it.
      user = insert_user()
      vault = insert(:vault, user: user)
      client = insert(:oauth_client, kind: "mcp")

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: nil
      )

      assert :ok = Connections.revoke_by_vault(user.id, vault.id)

      # The unbound grant survives, it was never the deleted vault's connection
      assert Connections.count_active(user.id, :mcp) == 1
    end

    test "narrows a multi-vault grant instead of revoking it" do
      # Deleting B must not cost the user A and C — vaults this grant covers
      # and the deletion never touched.
      %{user: user, a: a, b: b, c: c, token: token} = multi_vault_grant()

      assert :ok = Connections.revoke_by_vault(user.id, b.id)

      token = Engram.Repo.get!(Engram.OAuth.RefreshToken, token.id, skip_tenant_check: true)
      assert is_nil(token.revoked_at)
      assert Enum.sort(token.vault_ids) == Enum.sort([a.id, c.id])
    end

    test "revokes once the LAST granted vault is deleted" do
      %{user: user, a: a, b: b, c: c, token: token} = multi_vault_grant()

      assert :ok = Connections.revoke_by_vault(user.id, b.id)
      assert :ok = Connections.revoke_by_vault(user.id, c.id)
      assert :ok = Connections.revoke_by_vault(user.id, a.id)

      token = Engram.Repo.get!(Engram.OAuth.RefreshToken, token.id, skip_tenant_check: true)
      refute is_nil(token.revoked_at)
    end

    test "revokes a single-vault array grant outright" do
      user = insert_user()
      vault = insert(:vault, user: user)
      client = insert(:oauth_client, kind: "mcp")

      token =
        insert(:oauth_refresh_token,
          user_id: user.id,
          client_id: client.client_id,
          vault_id: vault.id,
          vault_ids: [vault.id]
        )

      assert :ok = Connections.revoke_by_vault(user.id, vault.id)

      token = Engram.Repo.get!(Engram.OAuth.RefreshToken, token.id, skip_tenant_check: true)
      refute is_nil(token.revoked_at)
    end

    test "revokes a legacy scalar-only row (vault_ids never written)" do
      user = insert_user()
      vault = insert(:vault, user: user)
      client = insert(:oauth_client, kind: "mcp")

      # The shape every grant minted before multi-vault shipped still has on
      # disk: scalar set, array NULL. It has nothing to narrow.
      token =
        insert(:oauth_refresh_token,
          user_id: user.id,
          client_id: client.client_id,
          vault_id: vault.id,
          vault_ids: nil
        )

      assert :ok = Connections.revoke_by_vault(user.id, vault.id)

      token = Engram.Repo.get!(Engram.OAuth.RefreshToken, token.id, skip_tenant_check: true)
      refute is_nil(token.revoked_at)
    end

    test "leaves an all-vaults grant untouched" do
      user = insert_user()
      vault = insert(:vault, user: user)
      client = insert(:oauth_client, kind: "mcp")

      # Both columns NULL = every vault, including ones created later. A vault
      # deletion narrows nothing and revokes nothing here.
      token =
        insert(:oauth_refresh_token,
          user_id: user.id,
          client_id: client.client_id,
          vault_id: nil,
          vault_ids: nil
        )

      assert :ok = Connections.revoke_by_vault(user.id, vault.id)

      token = Engram.Repo.get!(Engram.OAuth.RefreshToken, token.id, skip_tenant_check: true)
      assert is_nil(token.revoked_at)
      assert is_nil(token.vault_ids)
    end
  end

  describe "revoke_oauth_family/3 with array grants" do
    test "matches a vault held only in vault_ids" do
      %{user: user, b: b, client: client, token: token} = multi_vault_grant()

      assert :ok = Connections.revoke_oauth_family(user.id, client.client_id, b.id)

      token = Engram.Repo.get!(Engram.OAuth.RefreshToken, token.id, skip_tenant_check: true)
      refute is_nil(token.revoked_at)
    end

    test "still matches a legacy scalar-only row" do
      user = insert_user()
      vault = insert(:vault, user: user)
      client = insert(:oauth_client, kind: "mcp")

      token =
        insert(:oauth_refresh_token,
          user_id: user.id,
          client_id: client.client_id,
          vault_id: vault.id,
          vault_ids: nil
        )

      assert :ok = Connections.revoke_oauth_family(user.id, client.client_id, vault.id)

      token = Engram.Repo.get!(Engram.OAuth.RefreshToken, token.id, skip_tenant_check: true)
      refute is_nil(token.revoked_at)
    end

    test "does not touch a grant that excludes the vault" do
      %{user: user, client: client, token: token} = multi_vault_grant()
      other = insert(:vault, user: user)

      assert :ok = Connections.revoke_oauth_family(user.id, client.client_id, other.id)

      token = Engram.Repo.get!(Engram.OAuth.RefreshToken, token.id, skip_tenant_check: true)
      assert is_nil(token.revoked_at)
    end
  end

  describe "list_for_user/2 vault scope" do
    test "a multi-vault grant is ONE row carrying every vault id and name" do
      %{user: user, a: a, b: b} = named_multi_vault_grant()

      assert [row] = Connections.list_for_user(user)
      assert Enum.sort(row.vault_ids) == Enum.sort([a.id, b.id])
      assert Enum.sort(row.vault_names) == ["Personal", "Work"]
    end

    test "a scoped caller never sees a non-granted vault's NAME" do
      # The leak this closes: RequireSession blocks API keys but not an
      # OAuth-grant internal JWT, so a token scoped to one vault reached the
      # unfiltered Vaults.list_vaults/1 lookup and read every name off it.
      %{user: user, a: a, b: b} = named_multi_vault_grant()

      scope = MapSet.new([a.id])
      assert [row] = Connections.list_for_user(user, scope)

      names = row.vault_names
      assert "Personal" in names
      refute "Work" in names
      # Positional against vault_ids: the out-of-scope slot is nil, not dropped.
      assert Enum.at(names, Enum.find_index(row.vault_ids, &(&1 == b.id))) == nil
    end

    test "an all-vaults grant lists with nil vault_ids and nil vault_names" do
      user = insert_user()
      client = insert(:oauth_client, kind: "mcp")
      insert(:oauth_refresh_token, user_id: user.id, client_id: client.client_id)

      assert [row] = Connections.list_for_user(user)
      assert is_nil(row.vault_ids)
      assert is_nil(row.vault_names)
    end

    test "two legacy scalar-only grants for one client stay two rows" do
      # DISTINCT keyed on vault_ids ALONE would collapse these: both carry a
      # NULL array, so the scalar column has to stay in the key.
      user = insert_user()
      client = insert(:oauth_client, kind: "mcp")
      one = insert(:vault, user: user)
      two = insert(:vault, user: user)

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: one.id
      )

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: two.id
      )

      ids = user |> Connections.list_for_user() |> Enum.flat_map(& &1.vault_ids)
      assert Enum.sort(ids) == Enum.sort([one.id, two.id])
    end

    test "two grants of ONE client are two rows, even over the same vaults" do
      # Under the old vault-keyed DISTINCT these collapsed into a single row
      # that no per-grant revoke could clear. `family_id` is what tells them
      # apart, and the labels are what let the user tell them apart.
      user = insert_user()
      client = insert(:oauth_client, kind: "mcp")
      vault = insert(:vault, user: user)

      for label <- ["laptop", "work"] do
        insert(:oauth_refresh_token,
          user_id: user.id,
          client_id: client.client_id,
          label: label,
          vault_id: nil,
          vault_ids: [vault.id]
        )
      end

      rows = Connections.list_for_user(user)
      assert Enum.sort(Enum.map(rows, & &1.name)) == ["laptop", "work"]
      assert length(Enum.uniq(Enum.map(rows, & &1.family_id))) == 2
    end

    test "PAT rows carry the same array shape (nil), never a scalar" do
      user = insert_user()
      insert(:api_key, user: user, name: "ci-bot")

      assert [row] = Connections.list_for_user(user)
      assert row.kind == :pat
      assert is_nil(row.vault_ids)
      refute Map.has_key?(row, :vault_id)
    end
  end

  # One MCP client the user authorized TWICE, over different vault sets — the
  # shape multi-vault consent makes reachable, and the one a client-wide
  # revoke gets wrong.
  defp two_grants_one_client do
    user = insert_user()
    client = insert(:oauth_client, kind: "mcp")
    work = insert(:vault, user: user)
    personal = insert(:vault, user: user)
    work_family = Ecto.UUID.generate()

    insert(:oauth_refresh_token,
      user_id: user.id,
      client_id: client.client_id,
      family_id: work_family,
      label: "work",
      vault_id: nil,
      vault_ids: [work.id]
    )

    insert(:oauth_refresh_token,
      user_id: user.id,
      client_id: client.client_id,
      label: "laptop",
      vault_id: nil,
      vault_ids: [personal.id]
    )

    %{user: user, client: client, work: work, personal: personal, work_family: work_family}
  end

  # One active MCP grant covering three vaults, in the post-release shape:
  # `vault_ids` is authoritative and the scalar is NULL (mint only dual-writes
  # it for single-vault grants).
  defp multi_vault_grant do
    user = insert_user()
    client = insert(:oauth_client, kind: "mcp")
    a = insert(:vault, user: user)
    b = insert(:vault, user: user)
    c = insert(:vault, user: user)

    token =
      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: nil,
        vault_ids: [a.id, b.id, c.id]
      )

    %{user: user, client: client, a: a, b: b, c: c, token: token}
  end

  # Same, but two vaults registered through the real encryption pipeline so
  # their names decrypt back — the factory's random ciphertext yields nil.
  defp named_multi_vault_grant do
    user = insert_user()
    # Free tier caps vaults at 1; this test needs two real ones.
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 5})
    {:ok, a, _} = Engram.Vaults.register_vault(user, "Personal", Ecto.UUID.generate())
    {:ok, b, _} = Engram.Vaults.register_vault(user, "Work", Ecto.UUID.generate())
    client = insert(:oauth_client, kind: "mcp")

    token =
      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: nil,
        vault_ids: [a.id, b.id]
      )

    %{user: user, client: client, a: a, b: b, token: token}
  end
end
