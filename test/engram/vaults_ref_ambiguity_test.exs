defmodule Engram.VaultsRefAmbiguityTest do
  @moduledoc """
  `slugify/1` is many-to-one on names (#1665). "Work Notes", "Work-Notes" and
  "work_notes" all reduce to `work-notes`, and `unique_slug/3` hands the second
  vault `work-notes-2`. Resolving a reference purely by slug therefore strips
  the distinction and always lands on whichever vault won the base slug — a
  silent wrong-target write from `write_note` / `delete_note`, reachable with
  nothing unusual in the account.

  Display names are encrypted at rest, so they cannot be matched in SQL. What
  can be matched is `name_hmac`, which is exactly what the encryption layer
  maintains for equality lookups on an encrypted column.
  """
  use Engram.DataCase, async: true

  alias Engram.Vaults

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})

    %{user: user}
  end

  defp register!(user, name) do
    {:ok, vault, _} = Vaults.register_vault(user, name, Ecto.UUID.generate())
    vault
  end

  describe "names that collide on a slug" do
    test "a colliding name resolves to ITS vault, not the one that won the slug", %{user: user} do
      a = register!(user, "Test Vault")
      b = register!(user, "Test-Vault")

      assert a.slug == "test-vault"
      assert b.slug == "test-vault-2", "precondition: unique_slug suffixed the collision"

      assert {:ok, got} = Vaults.get_vault_by_ref(user, "Test-Vault")
      assert got.id == b.id, "resolved the vault that won the base slug instead of the named one"

      assert {:ok, got_a} = Vaults.get_vault_by_ref(user, "Test Vault")
      assert got_a.id == a.id
    end

    test "the CJK default is not a magnet for a vault literally named Vault", %{user: user} do
      cjk = register!(user, "日本語")
      plain = register!(user, "Vault")

      assert cjk.slug == "vault", "precondition: no-ASCII-fallback default"

      assert {:ok, got} = Vaults.get_vault_by_ref(user, "Vault")
      assert got.id == plain.id
    end

    test "an exact slug still resolves, and beats nothing else", %{user: user} do
      a = register!(user, "Test Vault")
      b = register!(user, "Test-Vault")

      assert {:ok, got_a} = Vaults.get_vault_by_ref(user, a.slug)
      assert got_a.id == a.id

      assert {:ok, got_b} = Vaults.get_vault_by_ref(user, b.slug)
      assert got_b.id == b.id
    end
  end

  describe "genuinely ambiguous references" do
    test "two vaults sharing a display name refuse rather than guess", %{user: user} do
      a = register!(user, "Notes")
      b = register!(user, "Notes")

      assert a.id != b.id
      assert {:error, {:ambiguous_ref, ids}} = Vaults.get_vault_by_ref(user, "Notes")
      assert Enum.sort(ids) == Enum.sort([to_string(a.id), to_string(b.id)])
    end

    test "each of them is still reachable by its own unique slug", %{user: user} do
      a = register!(user, "Notes")
      b = register!(user, "Notes")

      assert {:ok, got_a} = Vaults.get_vault_by_ref(user, a.slug)
      assert got_a.id == a.id

      assert {:ok, got_b} = Vaults.get_vault_by_ref(user, b.slug)
      assert got_b.id == b.id
    end
  end

  describe "unchanged behaviour" do
    test "a UUID still resolves", %{user: user} do
      a = register!(user, "Test Vault")

      assert {:ok, got} = Vaults.get_vault_by_ref(user, a.id)
      assert got.id == a.id
    end

    test "an unknown reference is still not_found", %{user: user} do
      register!(user, "Test Vault")

      assert {:error, :not_found} = Vaults.get_vault_by_ref(user, "No Such Vault")
      assert {:error, :not_found} = Vaults.get_vault_by_ref(user, "日本語")
    end

    test "another user's name never resolves", %{user: user} do
      other = insert(:user)
      {:ok, other} = Engram.Crypto.ensure_user_dek(other)
      register!(other, "Their Vault")

      assert {:error, :not_found} = Vaults.get_vault_by_ref(user, "Their Vault")
    end
  end
end
