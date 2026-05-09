defmodule Engram.Crypto.UserDekRotationTest do
  use Engram.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Engram.Crypto
  alias Engram.Crypto.{DekCache, UserDekRotation}
  alias Engram.Repo

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture(dek_version: 1)
    {:ok, user: user}
  end

  describe "rotate_user/2 — lock handling" do
    test "returns {:error, :rotation_in_progress} when already locked", %{user: user} do
      Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^user.id),
        [set: [dek_rotation_locked_at: DateTime.utc_now()]],
        skip_tenant_check: true
      )

      assert {:error, :rotation_in_progress} = UserDekRotation.rotate_user(user.id, 2)
    end

    test "returns {:error, :not_found} for missing user" do
      assert {:error, :not_found} = UserDekRotation.rotate_user(999_999_999, 2)
    end

    test "returns :skipped when user.dek_version >= target", %{user: user} do
      Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^user.id),
        [set: [dek_version: 5]],
        skip_tenant_check: true
      )

      assert :skipped = UserDekRotation.rotate_user(user.id, 2)
    end
  end

  describe "rotate_user/2 — happy path with no ciphertext rows" do
    test "user with no notes/atts/vaults rotates cleanly", %{user: user} do
      old_wrapped = user.encrypted_dek
      assert :ok = UserDekRotation.rotate_user(user.id, 2)

      refreshed = Repo.reload!(user)
      assert refreshed.dek_version == 2
      refute refreshed.encrypted_dek == old_wrapped
      assert is_nil(refreshed.dek_rotation_locked_at)
    end

    test "DekCache invalidated after flip", %{user: user} do
      DekCache.put(user.id, :crypto.strong_rand_bytes(32))
      assert {:ok, _stale_dek} = DekCache.get(user.id)

      assert :ok = UserDekRotation.rotate_user(user.id, 2)

      assert :miss = DekCache.get(user.id)
    end
  end

  describe "rotate_user/2 — notes sweep" do
    setup %{user: user} do
      # Use dek_version: 2 so the vaults sweep skips this placeholder vault
      # (its name_ciphertext is random bytes, not a valid encryption).
      vault = insert(:vault, user: user, dek_version: 2)

      note_a =
        Engram.Fixtures.insert_note!(user, vault, %{
          path: "alpha.md",
          content: "alpha content"
        })

      note_b =
        Engram.Fixtures.insert_note!(user, vault, %{
          path: "beta.md",
          content: "beta content"
        })

      {:ok, vault: vault, note_a: note_a, note_b: note_b}
    end

    test "every note re-encrypts under the new DEK", %{user: user, note_a: a, note_b: b} do
      assert :ok = UserDekRotation.rotate_user(user.id, 2)

      reloaded_user =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id), skip_tenant_check: true)

      reloaded_a =
        Repo.one!(from(n in Engram.Notes.Note, where: n.id == ^a.id), skip_tenant_check: true)

      reloaded_b =
        Repo.one!(from(n in Engram.Notes.Note, where: n.id == ^b.id), skip_tenant_check: true)

      assert reloaded_a.dek_version == 2
      assert reloaded_b.dek_version == 2

      assert {:ok, decrypted_a} = Crypto.maybe_decrypt_note_fields(reloaded_a, reloaded_user)
      assert decrypted_a.content == "alpha content"

      assert {:ok, decrypted_b} = Crypto.maybe_decrypt_note_fields(reloaded_b, reloaded_user)
      assert decrypted_b.content == "beta content"
    end

    test "ciphertext bytes change post-rotation", %{user: user, note_a: a} do
      old_ct = a.content_ciphertext
      assert :ok = UserDekRotation.rotate_user(user.id, 2)

      reloaded =
        Repo.one!(from(n in Engram.Notes.Note, where: n.id == ^a.id), skip_tenant_check: true)

      refute reloaded.content_ciphertext == old_ct
    end
  end

  describe "rotate_user/2 — vaults sweep" do
    test "every vault re-encrypts under the new DEK", %{user: user} do
      vault = Engram.Fixtures.insert_vault!(user, "Personal")
      old_ct = vault.name_ciphertext

      assert :ok = UserDekRotation.rotate_user(user.id, 2)

      reloaded_user =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id), skip_tenant_check: true)

      reloaded_vault =
        Repo.one!(from(v in Engram.Vaults.Vault, where: v.id == ^vault.id), skip_tenant_check: true)

      assert reloaded_vault.dek_version == 2
      refute reloaded_vault.name_ciphertext == old_ct
      assert {:ok, decrypted} = Crypto.maybe_decrypt_vault_fields(reloaded_vault, reloaded_user)
      assert decrypted.name == "Personal"
    end
  end

  describe "rotate_user/2 — HMAC re-derivation" do
    setup %{user: user} do
      vault = Engram.Fixtures.insert_vault!(user, "Personal")

      note =
        Engram.Fixtures.insert_note!(user, vault, %{
          path: "alpha.md",
          content: "alpha",
          folder: "subfolder",
          tags: ["red", "blue"]
        })

      {:ok, vault: vault, note: note}
    end

    test "note path_hmac matches new filter_key after rotation", %{user: user, note: note} do
      assert :ok = UserDekRotation.rotate_user(user.id, 2)

      reloaded_user =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id), skip_tenant_check: true)

      reloaded_note =
        Repo.one!(from(n in Engram.Notes.Note, where: n.id == ^note.id), skip_tenant_check: true)

      {:ok, new_dek} = Crypto.get_dek(reloaded_user)
      new_filter_key = Crypto.dek_filter_key_from_bytes(new_dek)
      expected_path_hmac = Crypto.hmac_field(new_filter_key, "alpha.md")

      assert reloaded_note.path_hmac == expected_path_hmac
    end

    test "note folder_hmac matches new filter_key after rotation", %{user: user, note: note} do
      assert :ok = UserDekRotation.rotate_user(user.id, 2)

      reloaded_user =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id), skip_tenant_check: true)

      reloaded_note =
        Repo.one!(from(n in Engram.Notes.Note, where: n.id == ^note.id), skip_tenant_check: true)

      {:ok, new_dek} = Crypto.get_dek(reloaded_user)
      new_filter_key = Crypto.dek_filter_key_from_bytes(new_dek)
      expected_folder_hmac = Crypto.hmac_field(new_filter_key, "subfolder")

      assert reloaded_note.folder_hmac == expected_folder_hmac
    end

    test "note tags_hmac matches new filter_key after rotation", %{user: user, note: note} do
      assert :ok = UserDekRotation.rotate_user(user.id, 2)

      reloaded_user =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id), skip_tenant_check: true)

      reloaded_note =
        Repo.one!(from(n in Engram.Notes.Note, where: n.id == ^note.id), skip_tenant_check: true)

      {:ok, new_dek} = Crypto.get_dek(reloaded_user)
      new_filter_key = Crypto.dek_filter_key_from_bytes(new_dek)
      expected_red = Crypto.hmac_field(new_filter_key, "red")
      expected_blue = Crypto.hmac_field(new_filter_key, "blue")

      assert reloaded_note.tags_hmac == [expected_red, expected_blue]
    end

    test "vault name_hmac matches new filter_key after rotation", %{user: user, vault: vault} do
      assert :ok = UserDekRotation.rotate_user(user.id, 2)

      reloaded_user =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id), skip_tenant_check: true)

      reloaded_vault =
        Repo.one!(from(v in Engram.Vaults.Vault, where: v.id == ^vault.id), skip_tenant_check: true)

      {:ok, new_dek} = Crypto.get_dek(reloaded_user)
      new_filter_key = Crypto.dek_filter_key_from_bytes(new_dek)
      expected_name_hmac = Crypto.hmac_field(new_filter_key, "Personal")

      assert reloaded_vault.name_hmac == expected_name_hmac
    end
  end
end
