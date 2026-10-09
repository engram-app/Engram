defmodule Engram.Cache.RequestLookupsTest do
  # Not async: the caches and the query recorder's telemetry handler are global.
  use Engram.DataCase, async: false

  alias Engram.Accounts
  alias Engram.Billing
  alias Engram.QueryRecorder
  alias Engram.Vaults

  @caches [:user, :api_key, :api_key_scope, :subscription, :vaults]

  setup do
    for c <- @caches, do: Engram.Cache.clear_local(c)
    :ok
  end

  # What the AFTER-write trigger's pg_notify does on every node in prod; the
  # sandbox never commits, so tests deliver it by hand.
  defp notify(channel, payload) do
    send(Engram.Cache.Server, {:notification, self(), make_ref(), channel, payload})
    _ = :sys.get_state(Engram.Cache.Server)
    :ok
  end

  defp queries(fun), do: QueryRecorder.record(fun)

  defp count(qs, source), do: Enum.count(qs, &(&1.source == source))

  defp vault_user do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    user
  end

  describe "user" do
    test "get_user/1 hits the DB once across two calls" do
      user = insert(:user)

      {_, qs} =
        queries(fn ->
          assert Accounts.get_user(user.id).id == user.id
          assert Accounts.get_user(user.id).id == user.id
        end)

      assert count(qs, "users") == 1
    end

    test "user cache evicted on users UPDATE notification" do
      user = insert(:user)
      assert Accounts.get_user(user.id).deleted_at == nil

      {1, _} =
        Repo.update_all(from(u in Accounts.User, where: u.id == ^user.id),
          set: [deleted_at: DateTime.utc_now(:second)]
        )

      # Still the cached row until the trigger's NOTIFY lands.
      assert Accounts.get_user(user.id).deleted_at == nil
      notify("users_changed", user.id)
      assert %DateTime{} = Accounts.get_user(user.id).deleted_at
    end

    # The users trigger evicts every node on commit, but asynchronously. These
    # writers are followed on the SAME node by a read that must see them (a
    # rotation drains rooms whose checkpoints gate on the lock; a suspended
    # user's next request), so each evicts locally after its commit.
    test "RotationLock acquire and release are visible to the next get_user on the writing node" do
      user = insert(:user)
      assert Accounts.get_user(user.id).dek_rotation_locked_at == nil

      {:ok, _} = Engram.Crypto.RotationLock.acquire(user.id)
      assert %DateTime{} = Accounts.get_user(user.id).dek_rotation_locked_at

      :ok = Engram.Crypto.RotationLock.release(user.id)
      assert Accounts.get_user(user.id).dek_rotation_locked_at == nil
    end

    test "suspend, unsuspend and soft delete are visible on the writing node" do
      user = insert(:user)
      assert Accounts.get_user(user.id).suspended_at == nil

      {:ok, suspended} = Accounts.suspend(user)
      assert %DateTime{} = Accounts.get_user(user.id).suspended_at

      {:ok, _} = Accounts.unsuspend(suspended)
      assert Accounts.get_user(user.id).suspended_at == nil

      {:ok, _} = Accounts.soft_delete_user(user)
      assert %DateTime{} = Accounts.get_user(user.id).deleted_at
    end

    test "Lifecycle.soft_delete is visible on the writing node" do
      user = insert(:user)
      assert Accounts.get_user(user.id).deleted_at == nil
      :ok = Engram.Accounts.Lifecycle.soft_delete(user, :user)
      assert %DateTime{} = Accounts.get_user(user.id).deleted_at
    end

    test "update_user_encryption is visible on the writing node" do
      user = insert(:user)
      cached = Accounts.get_user(user.id)
      {:ok, provisioned} = Engram.Crypto.ensure_user_dek(cached)
      assert Accounts.get_user(user.id).encrypted_dek == provisioned.encrypted_dek
    end

    test "a missing user is not negatively cached" do
      id = Ecto.UUID.generate()
      assert Accounts.get_user(id) == nil
      assert Engram.Cache.get(:user, id) == :miss
    end
  end

  describe "api key" do
    test "second validate_api_key/1 issues 0 queries" do
      user = insert(:user)
      {:ok, raw, key} = Accounts.create_api_key(user, "k")

      assert {:ok, %Accounts.User{id: uid}, %Accounts.ApiKey{id: kid}} =
               Accounts.validate_api_key(raw)

      assert uid == user.id and kid == key.id

      {result, qs} = queries(fn -> Accounts.validate_api_key(raw) end)
      assert {:ok, %Accounts.User{}, %Accounts.ApiKey{}} = result
      assert qs == []
    end

    test "the cached key does not carry the user" do
      user = insert(:user)
      {:ok, raw, key} = Accounts.create_api_key(user, "k")
      {:ok, _, _} = Accounts.validate_api_key(raw)

      assert {:ok, %Accounts.ApiKey{user: %Ecto.Association.NotLoaded{}}} =
               Engram.Cache.get(:api_key, key.key_hash)
    end

    test "revoked key stops resolving after eviction" do
      user = insert(:user)
      {:ok, raw, key} = Accounts.create_api_key(user, "k")
      assert {:ok, _, _} = Accounts.validate_api_key(raw)

      :ok = Accounts.revoke_api_key(user, key.id)
      notify("api_keys_changed", key.key_hash)

      assert Accounts.validate_api_key(raw) == {:error, :invalid_key}
    end

    test "revoke_api_key/2 evicts the key on the writing node without the NOTIFY" do
      user = insert(:user)
      {:ok, raw, key} = Accounts.create_api_key(user, "k")
      assert {:ok, _, _} = Accounts.validate_api_key(raw)

      :ok = Accounts.revoke_api_key(user, key.id)

      assert Accounts.validate_api_key(raw) == {:error, :invalid_key}
    end

    test "a key whose user is gone does not resolve" do
      user = insert(:user)
      {:ok, raw, _key} = Accounts.create_api_key(user, "k")
      assert {:ok, _, _} = Accounts.validate_api_key(raw)

      {1, _} = Repo.delete_all(from(u in Accounts.User, where: u.id == ^user.id))
      notify("users_changed", user.id)

      # The key row cascaded away too, but its cache entry outlives it until
      # its own NOTIFY; the user lookup alone must already fail closed.
      assert Accounts.validate_api_key(raw) == {:error, :invalid_key}
    end

    test "an unknown key is not negatively cached" do
      assert Accounts.validate_api_key("engram_nope") == {:error, :invalid_key}
      user = insert(:user)
      {:ok, raw, _} = Accounts.create_api_key(user, "k")
      assert {:ok, _, _} = Accounts.validate_api_key(raw)
    end

    test "a soft-deleted user still resolves with deleted_at set (plugs reject it)" do
      user = insert(:user)
      {:ok, raw, _} = Accounts.create_api_key(user, "k")
      {:ok, _, _} = Accounts.validate_api_key(raw)

      {1, _} =
        Repo.update_all(from(u in Accounts.User, where: u.id == ^user.id),
          set: [suspended_at: DateTime.utc_now(:second)]
        )

      notify("users_changed", user.id)
      assert {:ok, %Accounts.User{suspended_at: %DateTime{}}, _} = Accounts.validate_api_key(raw)
    end
  end

  describe "subscription" do
    test "caches nil and reloads after subscriptions_changed" do
      user = insert(:user)
      assert Billing.get_subscription(user) == nil

      {_, qs} = queries(fn -> assert Billing.get_subscription(user) == nil end)
      assert qs == []

      insert(:subscription, user: user)
      assert Billing.get_subscription(user) == nil
      notify("subscriptions_changed", user.id)
      assert %Billing.Subscription{tier: "starter"} = Billing.get_subscription(user)
    end

    test "a loaded subscription association short-circuits" do
      user = insert(:user)
      sub = insert(:subscription, user: user)
      {_, qs} = queries(fn -> Billing.get_subscription(%{user | subscription: sub}) end)
      assert qs == []
    end
  end

  describe "vaults" do
    test "get_vault, get_default_vault and slug refs issue 0 queries after list_vaults" do
      user = vault_user()
      {:ok, vault, _} = Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
      assert [%{id: id}] = Vaults.list_vaults(user)
      assert id == vault.id

      {_, qs} =
        queries(fn ->
          assert {:ok, %{id: ^id}} = Vaults.get_vault(user, vault.id)
          assert {:ok, %{id: ^id}} = Vaults.get_default_vault(user)
          assert {:ok, %{id: ^id}} = Vaults.get_vault_by_ref(user, "test-vault")
          assert {:ok, %{id: ^id}} = Vaults.get_vault_by_ref(user, "Test Vault")
          assert {:ok, %{id: ^id}} = Vaults.get_vault_by_ref(user, to_string(id))
          assert Vaults.has_vault?(user)
        end)

      assert qs == []
    end

    test "name refs keep their rules: exact name wins over a colliding slug, ambiguity refuses" do
      user = vault_user()
      {:ok, a, _} = Vaults.register_vault(user, "Work Notes", Ecto.UUID.generate())
      {:ok, b, _} = Vaults.register_vault(user, "work-notes", Ecto.UUID.generate())

      assert {:ok, %{id: a_id}} = Vaults.get_vault_by_ref(user, "Work Notes")
      assert a_id == a.id
      assert {:ok, %{id: b_id}} = Vaults.get_vault_by_ref(user, "work-notes")
      assert b_id == b.id
      {:ok, _, _} = Vaults.register_vault(user, "Same", Ecto.UUID.generate())
      {:ok, _, _} = Vaults.register_vault(user, "Same", Ecto.UUID.generate())
      assert {:error, {:ambiguous_ref, [_, _]}} = Vaults.get_vault_by_ref(user, "Same")
      assert {:error, :not_found} = Vaults.get_vault_by_ref(user, "nope")
    end

    test "vault cache evicted on vaults UPDATE notification" do
      user = vault_user()
      {:ok, vault, _} = Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
      assert {:ok, _} = Vaults.get_vault(user, vault.id)

      # A raw writer (no app-level evict): only the NOTIFY makes it visible.
      {:ok, {1, _}} =
        Repo.with_tenant(user.id, fn ->
          Repo.update_all(from(v in Vaults.Vault, where: v.id == ^vault.id),
            set: [deleted_at: DateTime.utc_now(:second), is_default: false]
          )
        end)

      assert {:ok, _} = Vaults.get_vault(user, vault.id)
      notify("vaults_changed", user.id)
      assert Vaults.get_vault(user, vault.id) == {:error, :not_found}
    end

    test "delete_vault/2 evicts on the writing node" do
      user = vault_user()
      {:ok, vault, _} = Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
      assert {:ok, _} = Vaults.get_vault(user, vault.id)

      {:ok, _} = Vaults.delete_vault(user, vault.id)

      assert Vaults.get_vault(user, vault.id) == {:error, :not_found}
      assert Vaults.get_default_vault(user) == {:error, :no_default_vault}
      refute Vaults.has_vault?(user)
    end

    test "another user's id never returns the first user's vaults" do
      owner = vault_user()
      other = vault_user()
      {:ok, vault, _} = Vaults.register_vault(owner, "Mine", Ecto.UUID.generate())
      assert [_] = Vaults.list_vaults(owner)

      assert Vaults.list_vaults(other) == []
      assert Vaults.get_vault(other, vault.id) == {:error, :not_found}
      assert Vaults.get_vault_by_ref(other, "mine") == {:error, :not_found}
    end

    test "the :vaults loader runs under the user's tenant" do
      user = vault_user()
      {:ok, _, _} = Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())

      {_, qs} = queries(fn -> Vaults.list_vaults(user) end)
      assert count(qs, "tenant_enter") == 1
      assert count(qs, "vaults") == 1
    end
  end

  describe "api key scope" do
    test "accessible_vault_ids/1 caches per key id and reloads after api_key_vaults_changed" do
      user = vault_user()
      {:ok, vault, _} = Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
      {:ok, _raw, key} = Accounts.create_api_key(user, "k")

      assert Vaults.accessible_vault_ids(key) == :all
      {_, qs} = queries(fn -> assert Vaults.accessible_vault_ids(key) == :all end)
      assert qs == []

      Repo.insert_all("api_key_vaults", [
        %{api_key_id: Ecto.UUID.dump!(key.id), vault_id: Ecto.UUID.dump!(vault.id)}
      ])

      assert Vaults.accessible_vault_ids(key) == :all
      notify("api_key_vaults_changed", key.id)
      assert Vaults.accessible_vault_ids(key) == [vault.id]
    end
  end
end
