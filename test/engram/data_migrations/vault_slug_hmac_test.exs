defmodule Engram.DataMigrations.VaultSlugHmacTest do
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.Crypto
  alias Engram.DataMigrations.VaultSlugHmac
  alias Engram.Vaults
  alias Engram.Vaults.Vault

  defp raw(vault_id),
    do: Repo.one!(from(v in Vault, where: v.id == ^vault_id), skip_tenant_check: true)

  defp set_raw(vault_id, fields),
    do:
      Repo.update_all(from(v in Vault, where: v.id == ^vault_id), [set: fields],
        skip_tenant_check: true
      )

  defp id6(vault), do: String.slice(vault.id, -6, 6)

  defp hmac(user, slug) do
    {:ok, key} = Crypto.dek_filter_key(Repo.reload!(user))
    Crypto.hmac_field(key, slug)
  end

  defp capped_user do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
    user
  end

  defp resolves?(user, slug, vault_id) do
    match?({:ok, %{id: ^vault_id}}, Vaults.get_vault_by_ref(user, slug))
  end

  describe "clears the plaintext slug and keeps the URL" do
    test "a row the previous release wrote (slug and hmac consistent)" do
      user = insert(:user)
      {:ok, vault, _} = Vaults.register_vault(user, "Notes", Ecto.UUID.generate())
      set_raw(vault.id, slug: "notes")

      assert VaultSlugHmac.run_pass() == :done

      row = raw(vault.id)
      assert row.slug == nil
      refute row.slug_suffixed
      assert row.slug_hmac == hmac(user, "notes")
      assert resolves?(user, "notes", vault.id)
    end

    test "an id-suffixed row" do
      user = capped_user()
      {:ok, _first, _} = Vaults.register_vault(user, "Notes", Ecto.UUID.generate())
      {:ok, second, _} = Vaults.register_vault(user, "Notes", Ecto.UUID.generate())
      set_raw(second.id, slug: "notes-#{id6(second)}")

      assert VaultSlugHmac.run_pass() == :done

      assert raw(second.id).slug == nil
      assert raw(second.id).slug_suffixed
      assert resolves?(user, "notes-#{id6(second)}", second.id)
    end

    test "a stale plaintext slug does not override a current slug_hmac" do
      # A rename left the old slug in the column while slug_hmac already holds
      # the new one: the hmac is the truth, so the bare URL must survive.
      user = insert(:user)
      {:ok, vault, _} = Vaults.register_vault(user, "Old Name", Ecto.UUID.generate())
      {:ok, _} = Vaults.update_vault(user, vault.id, %{name: "New Name"})
      set_raw(vault.id, slug: "old-name")

      assert VaultSlugHmac.run_pass() == :done

      assert raw(vault.id).slug == nil
      refute raw(vault.id).slug_suffixed
      assert resolves?(user, "new-name", vault.id)
    end

    test "a suffixed slug stays suffixed when its base holder is deleted, so restore works" do
      user = capped_user()
      {:ok, a, _} = Vaults.register_vault(user, "Notes", Ecto.UUID.generate())
      {:ok, b, _} = Vaults.register_vault(user, "Notes", Ecto.UUID.generate())
      {:ok, _} = Vaults.delete_vault(user, a.id)
      set_raw(b.id, slug: "notes-#{id6(b)}")

      assert VaultSlugHmac.run_pass() == :done

      assert raw(b.id).slug_suffixed
      assert {:ok, _} = Vaults.restore_vault(user, a.id)
    end
  end

  describe "legacy rows whose hmac matches neither form" do
    test "a stale hmac with a current bare slug is repaired to the bare form" do
      user = insert(:user)
      {:ok, vault, _} = Vaults.register_vault(user, "Job", Ecto.UUID.generate())
      set_raw(vault.id, slug: "job", slug_hmac: hmac(user, "work"))

      assert VaultSlugHmac.run_pass() == :done

      assert raw(vault.id).slug_hmac == hmac(user, "job")
      assert resolves?(user, "job", vault.id)
    end

    test "an underivable slug maps to the id-suffixed form, never the bare base" do
      user = insert(:user)
      {:ok, vault, _} = Vaults.register_vault(user, "My Vault", Ecto.UUID.generate())
      set_raw(vault.id, slug: "my_vault", slug_hmac: nil)

      assert VaultSlugHmac.run_pass() == :done

      assert raw(vault.id).slug_suffixed
      assert resolves?(user, "my-vault-#{id6(vault)}", vault.id)
    end
  end

  test "is idempotent: a second run finds nothing to clear" do
    user = insert(:user)
    {:ok, vault, _} = Vaults.register_vault(user, "Work", Ecto.UUID.generate())
    set_raw(vault.id, slug: "work")

    assert {:ok, 1} = Vaults.backfill_slug_hmacs(user.id)
    after_first = raw(vault.id)
    assert {:ok, 0} = Vaults.backfill_slug_hmacs(user.id)
    assert raw(vault.id) == after_first
  end

  test "leaves an undecryptable row and its slug alone" do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user, slug: "unreadable")

    {result, log} = ExUnit.CaptureLog.with_log(fn -> VaultSlugHmac.run_pass() end)

    assert result == :more
    assert log =~ "vault slug not reconcilable"
    assert raw(vault.id).slug == "unreadable"
  end

  test "skips a user mid-rotation and clears them on a later run" do
    user = insert(:user)
    {:ok, vault, _} = Vaults.register_vault(user, "Work", Ecto.UUID.generate())
    set_raw(vault.id, slug: "work")

    Repo.update_all(from(u in Engram.Accounts.User, where: u.id == ^user.id),
      set: [dek_rotation_locked_at: DateTime.utc_now()]
    )

    assert {:error, :rotation_in_progress} = Vaults.backfill_slug_hmacs(user.id)
    assert raw(vault.id).slug == "work"

    Repo.update_all(from(u in Engram.Accounts.User, where: u.id == ^user.id),
      set: [dek_rotation_locked_at: nil]
    )

    assert VaultSlugHmac.run_pass() == :done
    assert raw(vault.id).slug == nil
  end

  test "a user with nothing to clear derives no key" do
    user = insert(:user, encrypted_dek: nil)
    _vault = insert(:vault, user: user)

    assert {:ok, 0} = Vaults.backfill_slug_hmacs(user.id)
  end

  test "a returned error (not a raise) is logged, not swallowed" do
    user = insert(:user)
    {:ok, vault, _} = Vaults.register_vault(user, "Work", Ecto.UUID.generate())
    set_raw(vault.id, slug: "work")

    Repo.update_all(from(u in Engram.Accounts.User, where: u.id == ^user.id),
      set: [encrypted_dek: nil]
    )

    {result, log} = ExUnit.CaptureLog.with_log(fn -> VaultSlugHmac.run_pass() end)

    assert result == :more
    assert log =~ "vault slug reconcile failed"
    assert raw(vault.id).slug == "work"
  end

  test "one user's failure does not stop the others" do
    broken = capped_user()
    {:ok, a, _} = Vaults.register_vault(broken, "Notes", Ecto.UUID.generate())
    # B's own slug is exactly A's suffixed target, so A's rewrite hits the
    # slug_hmac unique index whichever row goes first.
    {:ok, _b, _} = Vaults.register_vault(broken, "Notes #{id6(a)}", Ecto.UUID.generate())
    set_raw(a.id, slug: "legacy", slug_hmac: nil)

    healthy = insert(:user)
    {:ok, vault, _} = Vaults.register_vault(healthy, "Work", Ecto.UUID.generate())
    set_raw(vault.id, slug: "work")

    {result, log} = ExUnit.CaptureLog.with_log(fn -> VaultSlugHmac.run_pass() end)

    assert result == :more
    assert log =~ "vault slug reconcile failed"
    assert raw(a.id).slug == "legacy", "the broken user's transaction rolled back"
    assert raw(vault.id).slug == nil
  end

  describe "completion" do
    test "a pass that clears every row is :done, and so is the next" do
      user = insert(:user)
      {:ok, vault, _} = Vaults.register_vault(user, "Notes", Ecto.UUID.generate())
      set_raw(vault.id, slug: "notes")

      assert VaultSlugHmac.run_pass() == :done
      assert VaultSlugHmac.run_pass() == :done
    end

    test "a user mid-rotation keeps it open" do
      user = insert(:user)
      {:ok, vault, _} = Vaults.register_vault(user, "Notes", Ecto.UUID.generate())
      set_raw(vault.id, slug: "notes")
      lock_rotation(user)

      assert VaultSlugHmac.run_pass() == :more
    end
  end

  test "a soft-deleted user's plaintext slug does not hold the migration open" do
    user = insert(:user)
    {:ok, vault, _} = Vaults.register_vault(user, "Notes", Ecto.UUID.generate())
    set_raw(vault.id, slug: "notes")

    Repo.update_all(from(u in Engram.Accounts.User, where: u.id == ^user.id),
      set: [deleted_at: DateTime.utc_now()]
    )

    assert VaultSlugHmac.run_pass() == :done
  end

  defp lock_rotation(user) do
    Repo.update_all(from(u in Engram.Accounts.User, where: u.id == ^user.id),
      set: [dek_rotation_locked_at: DateTime.utc_now()]
    )
  end
end
