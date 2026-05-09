defmodule Engram.Crypto.UserDekRotationTest do
  use Engram.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Engram.Crypto.UserDekRotation
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
end
