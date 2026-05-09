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
      vault = insert(:vault, user: user)

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
end
