defmodule Engram.Crypto.RotationLockTest do
  use Engram.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts.User
  alias Engram.Crypto.RotationLock
  alias Engram.Repo

  setup do
    user = insert(:user)
    {:ok, user: user}
  end

  test "acquire/1 sets dek_rotation_locked_at when null", %{user: user} do
    assert {:ok, locked_at} = RotationLock.acquire(user.id)
    refreshed = Repo.get!(User, user.id, skip_tenant_check: true)
    assert DateTime.compare(refreshed.dek_rotation_locked_at, locked_at) == :eq
  end

  test "acquire/1 returns :rotation_in_progress when already locked < 10 min ago", %{user: user} do
    assert {:ok, _at} = RotationLock.acquire(user.id)

    assert {:error, :rotation_in_progress} =
             RotationLock.acquire(user.id)
  end

  test "acquire/1 takes over a stale lock (>10 min)", %{user: user} do
    stale = DateTime.add(DateTime.utc_now(), -11 * 60, :second)

    Repo.update_all(
      from(u in User, where: u.id == ^user.id),
      [set: [dek_rotation_locked_at: stale]],
      skip_tenant_check: true
    )

    assert {:ok, new_at} = RotationLock.acquire(user.id)
    assert DateTime.compare(new_at, stale) == :gt
  end

  test "release/1 clears dek_rotation_locked_at", %{user: user} do
    {:ok, _at} = RotationLock.acquire(user.id)
    assert :ok = RotationLock.release(user.id)
    refreshed = Repo.get!(User, user.id, skip_tenant_check: true)
    assert is_nil(refreshed.dek_rotation_locked_at)
  end

  test "locked?/1 reflects current state", %{user: user} do
    refute RotationLock.locked?(user.id)
    {:ok, _at} = RotationLock.acquire(user.id)
    assert RotationLock.locked?(user.id)
    :ok = RotationLock.release(user.id)
    refute RotationLock.locked?(user.id)
  end

  # ---------------------------------------------------------------------------
  # Phase A — B4: RotationLock.release/1 row-vanish
  # ---------------------------------------------------------------------------

  describe "Phase A — B4: release/1 row vanish" do
    test "release/1 raises RuntimeError with structured log when user row no longer exists",
         %{user: user} do
      {:ok, _at} = RotationLock.acquire(user.id)

      # Hard-delete the user row to simulate concurrent account deletion.
      Repo.delete_all(
        from(u in User, where: u.id == ^user.id),
        skip_tenant_check: true
      )

      assert_raise RuntimeError, ~r/T3\.7 RotationLock\.release: row vanished/, fn ->
        RotationLock.release(user.id)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Phase D — stale-takeover safety: refuse takeover if dek_version_pending set
  # ---------------------------------------------------------------------------

  describe "Phase D — stale-takeover safety" do
    test "acquire/2 refuses stale-takeover when user has attachments.dek_version_pending non-null",
         %{user: user} do
      stale = DateTime.add(DateTime.utc_now(), -11 * 60, :second)

      Repo.update_all(
        from(u in User, where: u.id == ^user.id),
        [set: [dek_rotation_locked_at: stale]],
        skip_tenant_check: true
      )

      vault = Engram.Fixtures.insert_vault!(user, "v")

      att = Engram.Fixtures.insert_attachment!(user, vault, %{path: "leaked.bin"})

      Repo.update_all(
        from(a in Engram.Attachments.Attachment, where: a.id == ^att.id),
        [set: [dek_version_pending: 99]],
        skip_tenant_check: true
      )

      assert {:error, :half_state_pending} = RotationLock.acquire(user.id)

      refreshed = Repo.get!(User, user.id, skip_tenant_check: true)
      assert DateTime.compare(refreshed.dek_rotation_locked_at, stale) == :eq
    end

    test "acquire/2 still takes over stale lock if no attachments are half-rotated",
         %{user: user} do
      stale = DateTime.add(DateTime.utc_now(), -11 * 60, :second)

      Repo.update_all(
        from(u in User, where: u.id == ^user.id),
        [set: [dek_rotation_locked_at: stale]],
        skip_tenant_check: true
      )

      vault = Engram.Fixtures.insert_vault!(user, "v")
      _att = Engram.Fixtures.insert_attachment!(user, vault, %{path: "clean.bin"})

      assert {:ok, new_at} = RotationLock.acquire(user.id)
      assert DateTime.compare(new_at, stale) == :gt
    end
  end
end
