defmodule Engram.VaultsTest do
  use Engram.DataCase, async: true
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Billing.OverrideCache
  alias Engram.Connections
  alias Engram.Vaults

  setup do
    user = insert(:user)
    other_user = insert(:user)
    %{user: user, other_user: other_user}
  end

  # B.2.6 tamper-plaintext tests retired with B.3 — the plaintext `name`
  # column no longer exists, so a tamper is impossible. Decryption is the
  # only path to a vault name now, exercised throughout the rest of the suite.

  # ---------------------------------------------------------------------------
  # register_vault/4
  # ---------------------------------------------------------------------------

  describe "register_vault/4" do
    test "creates a vault with generated slug", %{user: user} do
      assert {:ok, vault, _} = Vaults.register_vault(user, "My Notes", Ecto.UUID.generate())
      assert vault.name == "My Notes"
      assert vault.slug == "my-notes"
      assert vault.user_id == user.id
    end

    test "first vault is set as default", %{user: user} do
      assert {:ok, vault, _} = Vaults.register_vault(user, "First", Ecto.UUID.generate())
      assert vault.is_default == true
    end

    test "ignores unknown string keys instead of crashing", %{user: user} do
      # `extra_attrs` may carry raw params; an attacker-supplied key that is
      # not an existing atom must not raise (String.to_existing_atom).
      extra = %{"description" => "Notes", "__definitely_not_a_field__" => "x"}

      assert {:ok, vault, _} =
               Vaults.register_vault(user, "Notes", Ecto.UUID.generate(), extra)

      assert vault.name == "Notes"
      assert vault.description == "Notes"
    end

    test "second vault is not default", %{user: user} do
      {:ok, _, _} = Vaults.register_vault(user, "First", Ecto.UUID.generate())

      # Give the second user unlimited vaults via user_overrides or just test default (1) blocks
      # Override the limit so we can insert a second vault. The first create
      # cached the override MISS — evict so the grant is visible (same idiom
      # as PlanCache.invalidate after mid-test plan edits).
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 5})
      :ok = OverrideCache.evict(user.id)

      assert {:ok, vault2, _} = Vaults.register_vault(user, "Second", Ecto.UUID.generate())
      assert vault2.is_default == false
    end

    test "enforces default billing limit of 1", %{user: user} do
      {:ok, _, _} = Vaults.register_vault(user, "First", Ecto.UUID.generate())

      assert {:error, {:vault_limit_reached, 1, 1}} =
               Vaults.register_vault(user, "Second", Ecto.UUID.generate())
    end

    test "unlimited override (-1) allows any number of vaults", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})

      {:ok, _, _} = Vaults.register_vault(user, "First", Ecto.UUID.generate())
      {:ok, _, _} = Vaults.register_vault(user, "Second", Ecto.UUID.generate())
      {:ok, _, _} = Vaults.register_vault(user, "Third", Ecto.UUID.generate())
    end

    test "specific override enforces that exact limit", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 2})

      {:ok, _, _} = Vaults.register_vault(user, "First", Ecto.UUID.generate())
      {:ok, _, _} = Vaults.register_vault(user, "Second", Ecto.UUID.generate())

      assert {:error, {:vault_limit_reached, 2, 2}} =
               Vaults.register_vault(user, "Third", Ecto.UUID.generate())
    end

    test "override upgrade: blocked by default, then lifted", %{user: user} do
      {:ok, _, _} = Vaults.register_vault(user, "First", Ecto.UUID.generate())

      assert {:error, {:vault_limit_reached, 1, 1}} =
               Vaults.register_vault(user, "Second", Ecto.UUID.generate())

      # Lift the limit via per-user override. Earlier creates cached the
      # override MISS — evict so the grant is visible immediately.
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 5})
      :ok = OverrideCache.evict(user.id)

      {:ok, _, _} = Vaults.register_vault(user, "Second", Ecto.UUID.generate())
      {:ok, _, _} = Vaults.register_vault(user, "Third", Ecto.UUID.generate())
    end

    test "deduplicates slug collision with numeric suffix", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      {:ok, v1, _} = Vaults.register_vault(user, "Notes", Ecto.UUID.generate())
      {:ok, v2, _} = Vaults.register_vault(user, "Notes", Ecto.UUID.generate())

      assert v1.slug == "notes"
      assert v2.slug == "notes-2"
    end

    test "slug with triple collision gets -3 suffix", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      {:ok, _, _} = Vaults.register_vault(user, "Notes", Ecto.UUID.generate())
      {:ok, _, _} = Vaults.register_vault(user, "Notes", Ecto.UUID.generate())
      {:ok, v3, _} = Vaults.register_vault(user, "Notes", Ecto.UUID.generate())

      assert v3.slug == "notes-3"
    end

    test "a former reserved word is now just an ordinary slug", %{user: user} do
      # Vault URLs are `/v/:slug`, so "Settings" no longer collides with the
      # /settings route (nor with any Plug.Static mount, Phoenix scope, or
      # Cloudflare rule). It takes the bare slug: no rejection, no -2 suffix.
      # See docs/context/vault-url-prefix-and-collision-surface.md.
      assert {:ok, vault, _} = Vaults.register_vault(user, "Settings", Ecto.UUID.generate())
      assert vault.slug == "settings"
    end

    test "slug strips special characters", %{user: user} do
      assert {:ok, vault, _} = Vaults.register_vault(user, "My Vault!", Ecto.UUID.generate())
      assert vault.slug == "my-vault"
    end

    test "empty slug falls back to 'vault'", %{user: user} do
      assert {:ok, vault, _} = Vaults.register_vault(user, "!!!", Ecto.UUID.generate())
      assert vault.slug == "vault"
    end

    test "description rides along in extra_attrs", %{user: user} do
      assert {:ok, vault, _} =
               Vaults.register_vault(user, "Work", "client-abc", %{description: "Work notes"})

      assert vault.description == "Work notes"
      assert vault.client_id == "client-abc"
    end

    test "extra_attrs cannot override the computed columns", %{user: user} do
      # name/client_id/slug/user_id/is_default are derived, not caller input —
      # a caller that smuggles them through extra_attrs must not win.
      other = insert(:user)

      assert {:ok, vault, _} =
               Vaults.register_vault(user, "Real", "cid-real", %{
                 name: "Spoofed",
                 client_id: "cid-spoofed",
                 slug: "spoofed",
                 user_id: other.id,
                 is_default: false
               })

      assert vault.name == "Real"
      assert vault.client_id == "cid-real"
      assert vault.slug == "real"
      assert vault.user_id == user.id
      assert vault.is_default == true
    end

    test "requires a name", %{user: user} do
      # Phase B.3: name is virtual — a missing name means the encrypted trio
      # never gets injected, and the changeset surfaces that on the public
      # `name` field (never the internal ciphertext/nonce/hmac column names).
      assert {:error, changeset} = Vaults.register_vault(user, "", Ecto.UUID.generate())
      errors = errors_on(changeset)
      assert errors[:name] == ["can't be blank"]
      refute Map.has_key?(errors, :name_ciphertext)
    end

    test "rejects a blank name", %{user: user} do
      assert {:error, changeset} = Vaults.register_vault(user, "   ", Ecto.UUID.generate())
      assert errors_on(changeset)[:name] == ["can't be blank"]
    end

    test "update_vault rejects a blank name without touching the slug", %{user: user} do
      {:ok, vault, _} = Vaults.register_vault(user, "Keep Me", Ecto.UUID.generate())

      assert {:error, changeset} = Vaults.update_vault(user, vault.id, %{name: ""})
      assert errors_on(changeset)[:name] == ["can't be blank"]

      {:ok, reloaded} = Vaults.get_vault(user, vault.id)
      assert reloaded.name == "Keep Me"
      assert reloaded.slug == vault.slug
    end
  end

  # ---------------------------------------------------------------------------
  # content_counts_for/2 and content_counts/2
  # ---------------------------------------------------------------------------

  describe "content_counts_for/2 and content_counts/2" do
    setup %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
      {:ok, a, _} = Vaults.register_vault(user, "Alpha", Ecto.UUID.generate())
      {:ok, b, _} = Vaults.register_vault(user, "Beta", Ecto.UUID.generate())
      %{a: a, b: b}
    end

    test "counts active notes and attachments per vault", %{user: user, a: a, b: b} do
      insert_pair(:note, user: user, vault: a)
      insert(:note, user: user, vault: b)
      insert(:attachment, user: user, vault: a)

      counts = Vaults.content_counts_for(user, [a, b])

      assert counts[a.id] == %{notes: 2, attachments: 1}
      assert counts[b.id] == %{notes: 1, attachments: 0}
    end

    test "excludes soft-deleted notes and attachments", %{user: user, a: a} do
      insert(:note, user: user, vault: a)
      insert(:note, user: user, vault: a, deleted_at: DateTime.utc_now(:second))
      insert(:attachment, user: user, vault: a, deleted_at: DateTime.utc_now(:second))

      assert Vaults.content_counts_for(user, [a])[a.id] == %{notes: 1, attachments: 0}
    end

    test "does not bleed across users", %{user: user, other_user: other, a: a} do
      insert(:note, user: other, vault: build(:vault, user: other))
      insert(:note, user: user, vault: a)

      assert Vaults.content_counts_for(user, [a])[a.id] == %{notes: 1, attachments: 0}
    end

    # Structurally proves the user_id guard fires: this note shares vault a's id
    # but belongs to `other`. Vault-id filtering alone would count it; only the
    # explicit user_id clause excludes it.
    test "user_id guard excludes another user's row on the same vault_id", %{
      user: user,
      other_user: other,
      a: a
    } do
      insert(:note, user: other, vault: a)
      insert(:note, user: user, vault: a)

      assert Vaults.content_counts_for(user, [a])[a.id] == %{notes: 1, attachments: 0}
    end

    test "empty vault list returns empty map", %{user: user} do
      assert Vaults.content_counts_for(user, []) == %{}
    end

    test "content_counts/2 returns a single vault's counts", %{user: user, a: a} do
      insert(:note, user: user, vault: a)
      assert Vaults.content_counts(user, a.id) == %{notes: 1, attachments: 0}
    end

    test "content_counts/2 returns zeros for an empty vault", %{user: user, b: b} do
      assert Vaults.content_counts(user, b.id) == %{notes: 0, attachments: 0}
    end
  end

  # ---------------------------------------------------------------------------
  # register_vault/3
  # ---------------------------------------------------------------------------

  describe "register_vault/3" do
    test "creates a new vault and returns :created", %{user: user} do
      assert {:ok, vault, :created} = Vaults.register_vault(user, "My Vault", "client-1")
      assert vault.name == "My Vault"
      assert vault.client_id == "client-1"
    end

    test "rejects a blank name", %{user: user} do
      assert {:error, changeset} = Vaults.register_vault(user, "  ", "client-blank")
      assert errors_on(changeset)[:name] == ["can't be blank"]
    end

    test "rejects a blank client_id rather than minting a vault per retry", %{user: user} do
      # `cast/3` drops "" via Ecto's default `:empty_values`, so a blank
      # client_id would persist as NULL — and `where: v.client_id == ^""`
      # never matches NULL. Each retry would then create ANOTHER vault until
      # `vaults_cap` rejected it, inverting this function's whole contract.
      assert {:error, :invalid_client_id} = Vaults.register_vault(user, "My Vault", "")
      assert {:error, :invalid_client_id} = Vaults.register_vault(user, "My Vault", "   ")
      assert {:error, :invalid_client_id} = Vaults.register_vault(user, "My Vault", 123)
    end

    test "is idempotent — same client_id returns existing vault with :existing", %{user: user} do
      {:ok, vault1, :created} = Vaults.register_vault(user, "My Vault", "client-1")
      {:ok, vault2, :existing} = Vaults.register_vault(user, "My Vault", "client-1")
      assert vault1.id == vault2.id
    end

    test "existing check ignores deleted vaults", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      {:ok, vault, :created} = Vaults.register_vault(user, "My Vault", "client-1")
      Vaults.delete_vault(user, vault.id)

      # After delete, same client_id should create a new vault
      {:ok, new_vault, :created} = Vaults.register_vault(user, "My Vault", "client-1")
      refute new_vault.id == vault.id
    end

    test "returns :vault_limit_reached when default limit exceeded", %{user: user} do
      Vaults.register_vault(user, "First", "client-1")

      assert {:error, {:vault_limit_reached, 1, 1}} =
               Vaults.register_vault(user, "Second", "client-2")
    end

    test "client_id lookup is scoped per user", %{user: user, other_user: other_user} do
      # other user registers with same client_id
      {:ok, _, :created} = Vaults.register_vault(other_user, "Other Vault", "client-x")

      # user should create fresh (not find other's vault)
      {:ok, vault, :created} = Vaults.register_vault(user, "My Vault", "client-x")
      assert vault.user_id == user.id
    end
  end

  # ---------------------------------------------------------------------------
  # list_vaults/1
  # ---------------------------------------------------------------------------

  describe "list_vaults/1" do
    test "returns all non-deleted vaults for user", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      {:ok, v1, _} = Vaults.register_vault(user, "A", Ecto.UUID.generate())
      {:ok, v2, _} = Vaults.register_vault(user, "B", Ecto.UUID.generate())

      vaults = Vaults.list_vaults(user)
      ids = Enum.map(vaults, & &1.id)
      assert v1.id in ids
      assert v2.id in ids
    end

    test "excludes soft-deleted vaults", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      {:ok, v1, _} = Vaults.register_vault(user, "Keep", Ecto.UUID.generate())
      {:ok, v2, _} = Vaults.register_vault(user, "Delete", Ecto.UUID.generate())
      Vaults.delete_vault(user, v2.id)

      vaults = Vaults.list_vaults(user)
      ids = Enum.map(vaults, & &1.id)
      assert v1.id in ids
      refute v2.id in ids
    end

    test "does not return other user's vaults", %{user: user, other_user: other_user} do
      {:ok, my_vault, _} = Vaults.register_vault(user, "Mine", Ecto.UUID.generate())
      {:ok, their_vault, _} = Vaults.register_vault(other_user, "Theirs", Ecto.UUID.generate())

      my_list = Vaults.list_vaults(user)
      their_list = Vaults.list_vaults(other_user)

      assert Enum.any?(my_list, &(&1.id == my_vault.id))
      refute Enum.any?(my_list, &(&1.id == their_vault.id))
      assert Enum.any?(their_list, &(&1.id == their_vault.id))
      refute Enum.any?(their_list, &(&1.id == my_vault.id))
    end

    test "returns vaults ordered by inserted_at ascending", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      {:ok, v1, _} = Vaults.register_vault(user, "Alpha", Ecto.UUID.generate())
      # 1.1s gap ensures distinct second-precision `created_at` timestamps so the
      # secondary `v.id` ordering doesn't race with UUIDv7 sub-millisecond
      # tiebreaker randomness.
      Process.sleep(1100)
      {:ok, v2, _} = Vaults.register_vault(user, "Beta", Ecto.UUID.generate())

      [first, second | _] = Vaults.list_vaults(user)
      assert first.id == v1.id
      assert second.id == v2.id
    end
  end

  describe "list_deleted_vaults/1" do
    setup %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
      :ok
    end

    test "returns only soft-deleted vaults, newest-deleted first", %{user: user} do
      {:ok, keep, _} = Vaults.register_vault(user, "Keep", Ecto.UUID.generate())
      {:ok, gone, _} = Vaults.register_vault(user, "Gone", Ecto.UUID.generate())
      {:ok, _} = Vaults.delete_vault(user, gone.id)

      deleted = Vaults.list_deleted_vaults(user)

      assert Enum.map(deleted, & &1.id) == [gone.id]
      assert keep.id not in Enum.map(deleted, & &1.id)
      assert hd(deleted).name == "Gone"
    end

    test "excludes other users' deleted vaults", %{user: user, other_user: other} do
      insert(:user_limit_override, user: other, key: "vaults_cap", value: %{"v" => 10})
      {:ok, mine, _} = Vaults.register_vault(user, "Mine", Ecto.UUID.generate())
      {:ok, theirs, _} = Vaults.register_vault(other, "Theirs", Ecto.UUID.generate())
      {:ok, _} = Vaults.delete_vault(user, mine.id)
      {:ok, _} = Vaults.delete_vault(other, theirs.id)

      assert Enum.map(Vaults.list_deleted_vaults(user), & &1.id) == [mine.id]
    end
  end

  describe "restore_vault/2" do
    test "clears deleted_at and returns the vault", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
      {:ok, v, _} = Vaults.register_vault(user, "Temp", Ecto.UUID.generate())
      {:ok, _} = Vaults.delete_vault(user, v.id)

      assert {:ok, restored} = Vaults.restore_vault(user, v.id)
      assert restored.id == v.id
      assert restored.deleted_at == nil
      assert Enum.map(Vaults.list_vaults(user), & &1.id) |> Enum.member?(v.id)
      assert Vaults.list_deleted_vaults(user) == []
    end

    test "blocks restore when it would exceed the vault cap", %{user: user} do
      # Cap of 1: create one, delete it, create a replacement, then try to restore.
      {:ok, first, _} = Vaults.register_vault(user, "First", Ecto.UUID.generate())
      {:ok, _} = Vaults.delete_vault(user, first.id)
      {:ok, _replacement, _} = Vaults.register_vault(user, "Replacement", Ecto.UUID.generate())

      assert {:error, {:limit_reached, 1, 1}} = Vaults.restore_vault(user, first.id)
      # Blocked restore leaves the vault soft-deleted: it stays in the trash
      # list and is NOT promoted back into the active list.
      assert first.id in deleted_ids(user)
      assert first.id not in Enum.map(Vaults.list_vaults(user), & &1.id)
    end

    test "returns :not_found for an active vault", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
      {:ok, v, _} = Vaults.register_vault(user, "Active", Ecto.UUID.generate())
      assert {:error, :not_found} = Vaults.restore_vault(user, v.id)
    end

    test "returns :not_found for another user's deleted vault", %{user: user, other_user: other} do
      insert(:user_limit_override, user: other, key: "vaults_cap", value: %{"v" => 10})
      {:ok, v, _} = Vaults.register_vault(other, "Theirs", Ecto.UUID.generate())
      {:ok, _} = Vaults.delete_vault(other, v.id)
      assert {:error, :not_found} = Vaults.restore_vault(user, v.id)
    end

    defp deleted_ids(user), do: Enum.map(Vaults.list_deleted_vaults(user), & &1.id)
  end

  # ---------------------------------------------------------------------------
  # purge_vault/2
  # ---------------------------------------------------------------------------

  describe "purge_vault/2" do
    test "enqueues an immediate force cleanup for a soft-deleted vault", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
      {:ok, v, _} = Vaults.register_vault(user, "Doomed", Ecto.UUID.generate())
      {:ok, _} = Vaults.delete_vault(user, v.id)

      assert {:ok, vault} = Vaults.purge_vault(user, v.id)
      assert vault.id == v.id

      assert_enqueued(
        worker: Engram.Workers.CleanupVault,
        args: %{vault_id: v.id, user_id: user.id, force: true}
      )
    end

    test "returns :not_found for an active vault", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
      {:ok, v, _} = Vaults.register_vault(user, "Active", Ecto.UUID.generate())
      assert {:error, :not_found} = Vaults.purge_vault(user, v.id)
      refute_enqueued(worker: Engram.Workers.CleanupVault)
    end
  end

  # ---------------------------------------------------------------------------
  # get_vault/2
  # ---------------------------------------------------------------------------

  describe "get_vault/2" do
    test "returns {:ok, vault} for owned vault", %{user: user} do
      {:ok, vault, _} = Vaults.register_vault(user, "Mine", Ecto.UUID.generate())
      assert {:ok, found} = Vaults.get_vault(user, vault.id)
      assert found.id == vault.id
    end

    test "returns {:error, :not_found} for unknown id", %{user: user} do
      assert {:error, :not_found} = Vaults.get_vault(user, Ecto.UUID.generate())
    end

    test "returns {:error, :not_found} for a malformed (non-UUID) id without raising", %{
      user: user
    } do
      assert {:error, :not_found} = Vaults.get_vault(user, "not-a-uuid")
    end

    test "returns {:error, :not_found} for another user's vault", %{
      user: user,
      other_user: other_user
    } do
      {:ok, their_vault, _} = Vaults.register_vault(other_user, "Theirs", Ecto.UUID.generate())
      assert {:error, :not_found} = Vaults.get_vault(user, their_vault.id)
    end

    test "returns {:error, :not_found} for soft-deleted vault", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      {:ok, vault, _} = Vaults.register_vault(user, "Gone", Ecto.UUID.generate())
      Vaults.delete_vault(user, vault.id)
      assert {:error, :not_found} = Vaults.get_vault(user, vault.id)
    end
  end

  # ---------------------------------------------------------------------------
  # get_default_vault/1
  # ---------------------------------------------------------------------------

  describe "get_default_vault/1" do
    test "returns the default vault", %{user: user} do
      {:ok, vault, _} = Vaults.register_vault(user, "Default", Ecto.UUID.generate())
      assert {:ok, found} = Vaults.get_default_vault(user)
      assert found.id == vault.id
    end

    test "returns {:error, :no_default_vault} when no vaults exist", %{user: user} do
      assert {:error, :no_default_vault} = Vaults.get_default_vault(user)
    end
  end

  # ---------------------------------------------------------------------------
  # update_vault/3
  # ---------------------------------------------------------------------------

  describe "update_vault/3" do
    test "updates name and description", %{user: user} do
      {:ok, vault, _} = Vaults.register_vault(user, "Old Name", Ecto.UUID.generate())

      assert {:ok, updated} =
               Vaults.update_vault(user, vault.id, %{name: "New Name", description: "Desc"})

      assert updated.name == "New Name"
      assert updated.description == "Desc"
    end

    test "regenerates slug when name changes", %{user: user} do
      {:ok, vault, _} = Vaults.register_vault(user, "Original", Ecto.UUID.generate())
      assert vault.slug == "original"

      assert {:ok, updated} = Vaults.update_vault(user, vault.id, %{name: "Renamed Vault"})
      assert updated.slug == "renamed-vault"
    end

    test "renaming into a former reserved word takes the bare slug", %{
      user: user
    } do
      {:ok, vault, _} = Vaults.register_vault(user, "Original", Ecto.UUID.generate())

      assert {:ok, updated} = Vaults.update_vault(user, vault.id, %{name: "Search"})
      assert updated.slug == "search"
    end

    test "setting is_default clears other defaults", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      {:ok, v1, _} = Vaults.register_vault(user, "First", Ecto.UUID.generate())
      {:ok, v2, _} = Vaults.register_vault(user, "Second", Ecto.UUID.generate())
      assert v1.is_default == true
      assert v2.is_default == false

      {:ok, updated_v2} = Vaults.update_vault(user, v2.id, %{is_default: true})
      assert updated_v2.is_default == true

      # v1 should no longer be default
      {:ok, refreshed_v1} = Vaults.get_vault(user, v1.id)
      assert refreshed_v1.is_default == false
    end

    test "returns {:error, :not_found} for missing vault", %{user: user} do
      assert {:error, :not_found} =
               Vaults.update_vault(user, Ecto.UUID.generate(), %{name: "X"})
    end
  end

  # ---------------------------------------------------------------------------
  # delete_vault/2
  # ---------------------------------------------------------------------------

  describe "delete_vault/2" do
    test "kills live CRDT rooms for the vault's notes (#954)", %{user: user} do
      # Rooms outliving their vault caused the 2026-07-07 checkpoint storms:
      # the orphaned room kept ticking against rows being deleted. Soft-delete
      # is the choke point — clients get vault_deleted and disconnect anyway.
      Process.flag(:trap_exit, true)
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      {:ok, vault, _} = Vaults.register_vault(user, "Rooms", Ecto.UUID.generate())

      {:ok, note} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "r.md",
          "content" => "x",
          "mtime" => 1.0
        })

      {:ok, room} =
        Yex.Sync.SharedDoc.start_link(
          [
            doc_name: note.id,
            doc_option: %Yex.Doc.Options{offset_kind: :utf16},
            auto_exit: false
          ],
          name: Engram.Notes.CrdtRegistry.global_name(note.id)
        )

      ref = Process.monitor(room)

      assert {:ok, _} = Vaults.delete_vault(user, vault.id)

      assert_receive {:DOWN, ^ref, :process, ^room, :killed}, 1000
      assert Engram.Notes.CrdtRegistry.lookup(note.id) == nil
    end

    test "kill_live_rooms_for_vault never raises (post-commit cleanup)", %{user: user} do
      # Runs inside delete_vault's post-commit tap: a raise there would 500 a
      # COMMITTED delete and skip the GateCache eviction. Cleanup must not
      # fail the write (same convention as CrdtDeliver). A non-UUID vault_id
      # makes Repo.all raise Ecto.Query.CastError — stand-in for any DB error.
      assert :ok = Engram.Notes.kill_live_rooms_for_vault(user.id, "not-a-uuid")
    end

    test "soft-deletes vault by setting deleted_at", %{user: user} do
      {:ok, vault, _} = Vaults.register_vault(user, "Temp", Ecto.UUID.generate())
      assert {:ok, deleted} = Vaults.delete_vault(user, vault.id)
      assert deleted.deleted_at != nil
      assert deleted.is_default == false
    end

    test "promotes next vault to default when default is deleted", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      {:ok, v1, _} = Vaults.register_vault(user, "First", Ecto.UUID.generate())
      {:ok, v2, _} = Vaults.register_vault(user, "Second", Ecto.UUID.generate())
      assert v1.is_default == true

      Vaults.delete_vault(user, v1.id)

      {:ok, promoted} = Vaults.get_default_vault(user)
      assert promoted.id == v2.id

      # Exactly one, stated outright: get_default_vault/1 is a Repo.one, so a
      # second is_default row makes it RAISE rather than return a wrong vault.
      # Asserting the count fails with "2 != 1" instead of an Ecto stacktrace.
      assert Enum.count(Vaults.list_vaults(user), & &1.is_default) == 1
    end

    test "does not promote when non-default vault is deleted", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      {:ok, v1, _} = Vaults.register_vault(user, "First", Ecto.UUID.generate())
      {:ok, v2, _} = Vaults.register_vault(user, "Second", Ecto.UUID.generate())

      Vaults.delete_vault(user, v2.id)

      {:ok, still_default} = Vaults.get_default_vault(user)
      assert still_default.id == v1.id
    end

    test "returns {:error, :not_found} for missing vault", %{user: user} do
      assert {:error, :not_found} = Vaults.delete_vault(user, Ecto.UUID.generate())
    end

    test "delete_vault enqueues the deletion-notice email", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
      {:ok, v, _} = Vaults.register_vault(user, "Bye", Ecto.UUID.generate())
      {:ok, _} = Vaults.delete_vault(user, v.id)

      assert_enqueued(
        worker: Engram.Workers.VaultDeletedEmail,
        args: %{vault_id: v.id, user_id: user.id}
      )
    end

    test "revokes vault-scoped OAuth and device tokens on soft-delete", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
      {:ok, gone, _} = Vaults.register_vault(user, "Gone", Ecto.UUID.generate())
      {:ok, kept, _} = Vaults.register_vault(user, "Kept", Ecto.UUID.generate())
      client = insert(:oauth_client, kind: "mcp")

      # Connections on the doomed vault…
      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: gone.id
      )

      insert(:device_refresh_token, user: user, vault: gone, family_id: Ecto.UUID.generate())

      # …and connections on a vault that survives.
      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: kept.id
      )

      insert(:device_refresh_token, user: user, vault: kept, family_id: Ecto.UUID.generate())

      assert {:ok, _} = Vaults.delete_vault(user, gone.id)

      # The deleted vault's connections vanish from the page immediately (the
      # #764 symptom is the connections list, not just the active count).
      vault_ids =
        user |> Connections.list_for_user() |> Enum.flat_map(&(&1.vault_ids || []))

      refute gone.id in vault_ids
      assert kept.id in vault_ids

      # Both kept-vault token kinds remain active — no collateral revocation.
      assert Connections.count_active(user.id, :mcp) == 1
      assert Connections.count_active(user.id, :obsidian) == 1
    end
  end

  describe "list_for_ids/2" do
    test "returns map keyed by stringified vault id" do
      user = insert(:user)
      v1 = insert(:vault, user: user)
      v2 = insert(:vault, user: user)

      result = Engram.Vaults.list_for_ids(user, [to_string(v1.id), to_string(v2.id)])

      assert Map.keys(result) |> Enum.sort() ==
               Enum.sort([to_string(v1.id), to_string(v2.id)])

      assert result[to_string(v1.id)].id == v1.id
    end

    test "filters out other users' vaults" do
      user_a = insert(:user)
      user_b = insert(:user)
      v_a = insert(:vault, user: user_a)
      v_b = insert(:vault, user: user_b)

      # user_a requests both IDs — only their own vault returned
      result = Engram.Vaults.list_for_ids(user_a, [to_string(v_a.id), to_string(v_b.id)])

      assert Map.keys(result) == [to_string(v_a.id)]
    end

    test "deduplicates and tolerates non-integer strings" do
      user = insert(:user)
      vault = insert(:vault, user: user)

      result =
        Engram.Vaults.list_for_ids(user, [
          to_string(vault.id),
          to_string(vault.id),
          "not-a-number",
          ""
        ])

      assert result == %{to_string(vault.id) => result[to_string(vault.id)]}
    end

    test "empty list returns empty map" do
      user = insert(:user)
      assert Engram.Vaults.list_for_ids(user, []) == %{}
    end

    test "excludes soft-deleted vaults" do
      user = insert(:user)

      deleted =
        insert(:vault,
          user: user,
          deleted_at: DateTime.utc_now(:second)
        )

      assert Engram.Vaults.list_for_ids(user, [to_string(deleted.id)]) == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Phase B.1 dual-write
  # ---------------------------------------------------------------------------

  describe "Phase B dual-write" do
    setup do
      user = insert(:user) |> Engram.Crypto.ensure_user_dek() |> elem(1)
      %{user: user}
    end

    test "register_vault populates name_hmac/ciphertext/nonce", %{user: user} do
      {:ok, vault, _} = Vaults.register_vault(user, "client-acme", Ecto.UUID.generate())

      {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
      expected_hmac = Engram.Crypto.hmac_field(filter_key, "client-acme")

      assert vault.name_hmac == expected_hmac
      assert is_binary(vault.name_ciphertext)
      assert byte_size(vault.name_nonce) == 12
      assert vault.name == "client-acme"
    end

    test "update_vault re-encrypts name on change", %{user: user} do
      {:ok, vault, _} = Vaults.register_vault(user, "old-name", Ecto.UUID.generate())
      {:ok, updated} = Vaults.update_vault(user, vault.id, %{name: "new-name"})

      {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
      expected = Engram.Crypto.hmac_field(filter_key, "new-name")

      assert updated.name_hmac == expected
      refute updated.name_hmac == vault.name_hmac
    end

    # The "update_vault ensures user DEK before name HMAC injection"
    # legacy-migration test was retired with B.3: vaults can no longer be
    # inserted without ciphertext (NOT NULL), so a pre-DEK vault row is
    # impossible. Remaining update_vault tests above already cover the
    # provisioning path on a clean fixture.
  end

  # ---------------------------------------------------------------------------
  # list_vaults — same-second created_at ordering
  # ---------------------------------------------------------------------------

  describe "list_vaults ordering" do
    # Regression: two vaults inserted in the same Postgres-rounded second tied on
    # created_at; without the `asc: v.id` tiebreaker the order was undefined and
    # tests flaked. These tests pin that the id tiebreaker is always respected.

    test "orders deterministically when created_at ties", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
      same_time = DateTime.utc_now(:second)

      {:ok, v1, _} = Vaults.register_vault(user, "vault-order-a", Ecto.UUID.generate())
      {:ok, v2, _} = Vaults.register_vault(user, "vault-order-b", Ecto.UUID.generate())

      # Force both vaults to the same created_at timestamp via Repo.update_all
      Engram.Repo.update_all(
        Ecto.Query.from(v in Engram.Vaults.Vault, where: v.id in ^[v1.id, v2.id]),
        [set: [created_at: same_time]],
        skip_tenant_check: true
      )

      vaults = Vaults.list_vaults(user)
      ids = Enum.map(vaults, & &1.id)

      assert ids == Enum.sort(ids),
             "expected ascending id tiebreaker, got #{inspect(ids)}"
    end

    test "id tiebreaker holds for three vaults at the same timestamp", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
      same_time = DateTime.utc_now(:second)

      {:ok, v1, _} = Vaults.register_vault(user, "alpha", Ecto.UUID.generate())
      {:ok, v2, _} = Vaults.register_vault(user, "beta", Ecto.UUID.generate())
      {:ok, v3, _} = Vaults.register_vault(user, "gamma", Ecto.UUID.generate())

      Engram.Repo.update_all(
        Ecto.Query.from(v in Engram.Vaults.Vault,
          where: v.id in ^[v1.id, v2.id, v3.id]
        ),
        [set: [created_at: same_time]],
        skip_tenant_check: true
      )

      vaults = Vaults.list_vaults(user)
      ids = Enum.map(vaults, & &1.id)

      assert ids == Enum.sort(ids),
             "expected ascending id order across 3-way tie, got #{inspect(ids)}"
    end
  end

  describe "pricing v2 §J — vault_count telemetry" do
    setup %{user: user} do
      # Default Free tier allows 1 vault; raise the cap so multi-vault test paths
      # don't hit :vault_limit_reached.
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 5})

      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :abuse, :vault_count]])
      on_exit(fn -> :telemetry.detach(ref) end)
      :ok
    end

    # `:telemetry_test.attach_event_handlers` attaches a global handler that
    # routes to self(); concurrent async tests firing :vault_count also land
    # in this test's mailbox. Pin user_id in every pattern so we only match
    # our own user's events.
    test "emits :vault_count on vault creation", %{user: user} do
      user_id = user.id
      assert {:ok, _, _} = Vaults.register_vault(user, "V1", Ecto.UUID.generate())

      assert_received {[:engram, :abuse, :vault_count], _ref, %{count: 1},
                       %{user_id: ^user_id, op: :created}}

      assert {:ok, _, _} = Vaults.register_vault(user, "V2", Ecto.UUID.generate())

      assert_received {[:engram, :abuse, :vault_count], _, %{count: 2},
                       %{user_id: ^user_id, op: :created}}
    end

    test "emits :vault_count on delete_vault success", %{user: user} do
      user_id = user.id
      {:ok, v, _} = Vaults.register_vault(user, "V1", Ecto.UUID.generate())
      drain_vault_count_messages()

      assert {:ok, _} = Vaults.delete_vault(user, v.id)

      assert_received {[:engram, :abuse, :vault_count], _ref, %{count: 0},
                       %{user_id: ^user_id, op: :deleted}}
    end

    test "emits :vault_count on register_vault when newly created", %{user: user} do
      user_id = user.id
      assert {:ok, _, :created} = Vaults.register_vault(user, "Reg", "client-xyz")

      assert_received {[:engram, :abuse, :vault_count], _, %{count: 1},
                       %{user_id: ^user_id, op: :created}}
    end
  end

  defp drain_vault_count_messages do
    receive do
      {[:engram, :abuse, :vault_count], _, _, _} -> drain_vault_count_messages()
    after
      0 -> :ok
    end
  end

  describe "register_vault/4 onboarding hook" do
    test "records first_vault_created on first vault" do
      user = insert(:user)
      assert [] = Engram.Onboarding.list_actions(user.id)

      {:ok, _v, _} = Engram.Vaults.register_vault(user, "Main", Ecto.UUID.generate())
      assert ["first_vault_created"] = Engram.Onboarding.list_actions(user.id)
    end

    test "second vault does not double-record" do
      user = insert(:user)
      {:ok, _, _} = Engram.Vaults.register_vault(user, "Main", Ecto.UUID.generate())
      # First create cached the override MISS — evict so the grant lands.
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 5})
      :ok = OverrideCache.evict(user.id)
      {:ok, _, _} = Engram.Vaults.register_vault(user, "Second", Ecto.UUID.generate())

      assert ["first_vault_created"] = Engram.Onboarding.list_actions(user.id)
    end
  end
end
