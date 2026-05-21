defmodule Engram.VaultsTest do
  use Engram.DataCase, async: true

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
  # create_vault/2
  # ---------------------------------------------------------------------------

  describe "create_vault/2" do
    test "creates a vault with generated slug", %{user: user} do
      assert {:ok, vault} = Vaults.create_vault(user, %{name: "My Notes"})
      assert vault.name == "My Notes"
      assert vault.slug == "my-notes"
      assert vault.user_id == user.id
    end

    test "first vault is set as default", %{user: user} do
      assert {:ok, vault} = Vaults.create_vault(user, %{name: "First"})
      assert vault.is_default == true
    end

    test "second vault is not default", %{user: user} do
      {:ok, _} = Vaults.create_vault(user, %{name: "First"})

      # Give the second user unlimited vaults via user_overrides or just test default (1) blocks
      # Override the limit so we can insert a second vault
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 5})

      assert {:ok, vault2} = Vaults.create_vault(user, %{name: "Second"})
      assert vault2.is_default == false
    end

    test "enforces default billing limit of 1", %{user: user} do
      {:ok, _} = Vaults.create_vault(user, %{name: "First"})

      assert {:error, :vault_limit_reached} = Vaults.create_vault(user, %{name: "Second"})
    end

    test "unlimited override (-1) allows any number of vaults", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})

      {:ok, _} = Vaults.create_vault(user, %{name: "First"})
      {:ok, _} = Vaults.create_vault(user, %{name: "Second"})
      {:ok, _} = Vaults.create_vault(user, %{name: "Third"})
    end

    test "specific override enforces that exact limit", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 2})

      {:ok, _} = Vaults.create_vault(user, %{name: "First"})
      {:ok, _} = Vaults.create_vault(user, %{name: "Second"})
      assert {:error, :vault_limit_reached} = Vaults.create_vault(user, %{name: "Third"})
    end

    test "override upgrade: blocked by default, then lifted", %{user: user} do
      {:ok, _} = Vaults.create_vault(user, %{name: "First"})
      assert {:error, :vault_limit_reached} = Vaults.create_vault(user, %{name: "Second"})

      # Lift the limit via per-user override
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 5})

      {:ok, _} = Vaults.create_vault(user, %{name: "Second"})
      {:ok, _} = Vaults.create_vault(user, %{name: "Third"})
    end

    test "deduplicates slug collision with numeric suffix", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      {:ok, v1} = Vaults.create_vault(user, %{name: "Notes"})
      {:ok, v2} = Vaults.create_vault(user, %{name: "Notes"})

      assert v1.slug == "notes"
      assert v2.slug == "notes-2"
    end

    test "slug with triple collision gets -3 suffix", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      {:ok, _} = Vaults.create_vault(user, %{name: "Notes"})
      {:ok, _} = Vaults.create_vault(user, %{name: "Notes"})
      {:ok, v3} = Vaults.create_vault(user, %{name: "Notes"})

      assert v3.slug == "notes-3"
    end

    test "slug strips special characters", %{user: user} do
      assert {:ok, vault} = Vaults.create_vault(user, %{name: "My Vault!"})
      assert vault.slug == "my-vault"
    end

    test "empty slug falls back to 'vault'", %{user: user} do
      assert {:ok, vault} = Vaults.create_vault(user, %{name: "!!!"})
      assert vault.slug == "vault"
    end

    test "description and client_id are optional", %{user: user} do
      assert {:ok, vault} =
               Vaults.create_vault(user, %{
                 name: "Work",
                 description: "Work notes",
                 client_id: "client-abc"
               })

      assert vault.description == "Work notes"
      assert vault.client_id == "client-abc"
    end

    test "requires a name", %{user: user} do
      # Phase B.3: name is virtual; the changeset surfaces the missing
      # ciphertext/nonce/hmac instead. Empty input therefore lands as a
      # "can't be blank" error on `name_ciphertext` and friends.
      assert {:error, changeset} = Vaults.create_vault(user, %{})
      errors = errors_on(changeset)
      assert "can't be blank" in (errors[:name_ciphertext] || [])
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

      assert {:error, :vault_limit_reached} =
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

      {:ok, v1} = Vaults.create_vault(user, %{name: "A"})
      {:ok, v2} = Vaults.create_vault(user, %{name: "B"})

      vaults = Vaults.list_vaults(user)
      ids = Enum.map(vaults, & &1.id)
      assert v1.id in ids
      assert v2.id in ids
    end

    test "excludes soft-deleted vaults", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      {:ok, v1} = Vaults.create_vault(user, %{name: "Keep"})
      {:ok, v2} = Vaults.create_vault(user, %{name: "Delete"})
      Vaults.delete_vault(user, v2.id)

      vaults = Vaults.list_vaults(user)
      ids = Enum.map(vaults, & &1.id)
      assert v1.id in ids
      refute v2.id in ids
    end

    test "does not return other user's vaults", %{user: user, other_user: other_user} do
      {:ok, my_vault} = Vaults.create_vault(user, %{name: "Mine"})
      {:ok, their_vault} = Vaults.create_vault(other_user, %{name: "Theirs"})

      my_list = Vaults.list_vaults(user)
      their_list = Vaults.list_vaults(other_user)

      assert Enum.any?(my_list, &(&1.id == my_vault.id))
      refute Enum.any?(my_list, &(&1.id == their_vault.id))
      assert Enum.any?(their_list, &(&1.id == their_vault.id))
      refute Enum.any?(their_list, &(&1.id == my_vault.id))
    end

    test "returns vaults ordered by inserted_at ascending", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      {:ok, v1} = Vaults.create_vault(user, %{name: "Alpha"})
      {:ok, v2} = Vaults.create_vault(user, %{name: "Beta"})

      [first, second | _] = Vaults.list_vaults(user)
      assert first.id == v1.id
      assert second.id == v2.id
    end
  end

  # ---------------------------------------------------------------------------
  # get_vault/2
  # ---------------------------------------------------------------------------

  describe "get_vault/2" do
    test "returns {:ok, vault} for owned vault", %{user: user} do
      {:ok, vault} = Vaults.create_vault(user, %{name: "Mine"})
      assert {:ok, found} = Vaults.get_vault(user, vault.id)
      assert found.id == vault.id
    end

    test "returns {:error, :not_found} for unknown id", %{user: user} do
      assert {:error, :not_found} = Vaults.get_vault(user, 0)
    end

    test "returns {:error, :not_found} for another user's vault", %{
      user: user,
      other_user: other_user
    } do
      {:ok, their_vault} = Vaults.create_vault(other_user, %{name: "Theirs"})
      assert {:error, :not_found} = Vaults.get_vault(user, their_vault.id)
    end

    test "returns {:error, :not_found} for soft-deleted vault", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      {:ok, vault} = Vaults.create_vault(user, %{name: "Gone"})
      Vaults.delete_vault(user, vault.id)
      assert {:error, :not_found} = Vaults.get_vault(user, vault.id)
    end
  end

  # ---------------------------------------------------------------------------
  # get_default_vault/1
  # ---------------------------------------------------------------------------

  describe "get_default_vault/1" do
    test "returns the default vault", %{user: user} do
      {:ok, vault} = Vaults.create_vault(user, %{name: "Default"})
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
      {:ok, vault} = Vaults.create_vault(user, %{name: "Old Name"})

      assert {:ok, updated} =
               Vaults.update_vault(user, vault.id, %{name: "New Name", description: "Desc"})

      assert updated.name == "New Name"
      assert updated.description == "Desc"
    end

    test "regenerates slug when name changes", %{user: user} do
      {:ok, vault} = Vaults.create_vault(user, %{name: "Original"})
      assert vault.slug == "original"

      assert {:ok, updated} = Vaults.update_vault(user, vault.id, %{name: "Renamed Vault"})
      assert updated.slug == "renamed-vault"
    end

    test "setting is_default clears other defaults", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      {:ok, v1} = Vaults.create_vault(user, %{name: "First"})
      {:ok, v2} = Vaults.create_vault(user, %{name: "Second"})
      assert v1.is_default == true
      assert v2.is_default == false

      {:ok, updated_v2} = Vaults.update_vault(user, v2.id, %{is_default: true})
      assert updated_v2.is_default == true

      # v1 should no longer be default
      {:ok, refreshed_v1} = Vaults.get_vault(user, v1.id)
      assert refreshed_v1.is_default == false
    end

    test "returns {:error, :not_found} for missing vault", %{user: user} do
      assert {:error, :not_found} = Vaults.update_vault(user, 0, %{name: "X"})
    end
  end

  # ---------------------------------------------------------------------------
  # delete_vault/2
  # ---------------------------------------------------------------------------

  describe "delete_vault/2" do
    test "soft-deletes vault by setting deleted_at", %{user: user} do
      {:ok, vault} = Vaults.create_vault(user, %{name: "Temp"})
      assert {:ok, deleted} = Vaults.delete_vault(user, vault.id)
      assert deleted.deleted_at != nil
      assert deleted.is_default == false
    end

    test "promotes next vault to default when default is deleted", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      {:ok, v1} = Vaults.create_vault(user, %{name: "First"})
      {:ok, v2} = Vaults.create_vault(user, %{name: "Second"})
      assert v1.is_default == true

      Vaults.delete_vault(user, v1.id)

      {:ok, promoted} = Vaults.get_default_vault(user)
      assert promoted.id == v2.id
    end

    test "does not promote when non-default vault is deleted", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      {:ok, v1} = Vaults.create_vault(user, %{name: "First"})
      {:ok, v2} = Vaults.create_vault(user, %{name: "Second"})

      Vaults.delete_vault(user, v2.id)

      {:ok, still_default} = Vaults.get_default_vault(user)
      assert still_default.id == v1.id
    end

    test "returns {:error, :not_found} for missing vault", %{user: user} do
      assert {:error, :not_found} = Vaults.delete_vault(user, 0)
    end
  end

  # ---------------------------------------------------------------------------
  # check_api_key_access/2
  # ---------------------------------------------------------------------------

  describe "check_api_key_access/2" do
    test "nil api_key (JWT auth) always returns :ok", %{user: user} do
      {:ok, vault} = Vaults.create_vault(user, %{name: "V"})
      assert :ok = Vaults.check_api_key_access(nil, vault)
    end

    test "unrestricted key (no api_key_vaults rows) returns :ok", %{user: user} do
      {:ok, vault} = Vaults.create_vault(user, %{name: "V"})
      {:ok, _raw, api_key} = Engram.Accounts.create_api_key(user, "unrestricted")

      assert :ok = Vaults.check_api_key_access(api_key, vault)
    end

    test "restricted key with matching vault returns :ok", %{user: user} do
      {:ok, vault} = Vaults.create_vault(user, %{name: "V"})
      {:ok, _raw, api_key} = Engram.Accounts.create_api_key(user, "restricted")

      Engram.Repo.insert_all("api_key_vaults", [
        %{api_key_id: api_key.id, vault_id: vault.id}
      ])

      assert :ok = Vaults.check_api_key_access(api_key, vault)
    end

    test "restricted key without matching vault returns :forbidden", %{
      user: user,
      other_user: other_user
    } do
      {:ok, vault} = Vaults.create_vault(user, %{name: "V"})
      {:ok, other_vault} = Vaults.create_vault(other_user, %{name: "Other"})
      {:ok, _raw, api_key} = Engram.Accounts.create_api_key(user, "restricted")

      # Restrict to other vault only
      Engram.Repo.insert_all("api_key_vaults", [
        %{api_key_id: api_key.id, vault_id: other_vault.id}
      ])

      assert :forbidden = Vaults.check_api_key_access(api_key, vault)
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

    test "create_vault populates name_hmac/ciphertext/nonce", %{user: user} do
      {:ok, vault} = Vaults.create_vault(user, %{name: "client-acme"})

      {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
      expected_hmac = Engram.Crypto.hmac_field(filter_key, "client-acme")

      assert vault.name_hmac == expected_hmac
      assert is_binary(vault.name_ciphertext)
      assert byte_size(vault.name_nonce) == 12
      assert vault.name == "client-acme"
    end

    test "update_vault re-encrypts name on change", %{user: user} do
      {:ok, vault} = Vaults.create_vault(user, %{name: "old-name"})
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

      {:ok, v1} = Vaults.create_vault(user, %{name: "vault-order-a"})
      {:ok, v2} = Vaults.create_vault(user, %{name: "vault-order-b"})

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

      {:ok, v1} = Vaults.create_vault(user, %{name: "alpha"})
      {:ok, v2} = Vaults.create_vault(user, %{name: "beta"})
      {:ok, v3} = Vaults.create_vault(user, %{name: "gamma"})

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
    test "emits :vault_count on create_vault success", %{user: user} do
      user_id = user.id
      assert {:ok, _} = Vaults.create_vault(user, %{name: "V1"})

      assert_received {[:engram, :abuse, :vault_count], _ref, %{count: 1},
                       %{user_id: ^user_id, op: :created}}

      assert {:ok, _} = Vaults.create_vault(user, %{name: "V2"})

      assert_received {[:engram, :abuse, :vault_count], _, %{count: 2},
                       %{user_id: ^user_id, op: :created}}
    end

    test "emits :vault_count on delete_vault success", %{user: user} do
      user_id = user.id
      {:ok, v} = Vaults.create_vault(user, %{name: "V1"})
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
end
