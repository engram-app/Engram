defmodule Engram.Crypto.UserDekRotationTest do
  use Engram.DataCase, async: false

  import Ecto.Query, only: [from: 2]

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
end
