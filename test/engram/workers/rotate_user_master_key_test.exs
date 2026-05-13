defmodule Engram.Workers.RotateUserMasterKeyTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Crypto
  alias Engram.Crypto.{DekCache, MasterRotation}
  alias Engram.Workers.RotateUserMasterKey

  setup do
    DekCache.invalidate_all()
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, user: user}
  end

  describe "perform/1" do
    test "rotates user when below target", %{user: user} do
      assert :ok =
               perform_job(RotateUserMasterKey, %{
                 "user_id" => user.id,
                 "target_version" => 2
               })

      assert Repo.reload!(user).dek_version == 2
    end

    test "is no-op (returns :ok) when user already at target", %{user: user} do
      assert :ok = MasterRotation.rotate_user(user, 2)

      assert :ok =
               perform_job(RotateUserMasterKey, %{
                 "user_id" => user.id,
                 "target_version" => 2
               })

      assert Repo.reload!(user).dek_version == 2
    end

    test "discards on missing user (no retry storms)" do
      assert {:discard, :user_deleted} =
               perform_job(RotateUserMasterKey, %{
                 "user_id" => 999_999,
                 "target_version" => 2
               })
    end

    test "discards on malformed args" do
      assert {:discard, {:invalid_args, _}} =
               perform_job(RotateUserMasterKey, %{"path" => "leak"})
    end
  end

  describe "enqueue_all/2" do
    test "inserts one job per below-target user", %{user: _user} do
      _b = insert(:user) |> Crypto.ensure_user_dek() |> elem(1)
      _c = insert(:user) |> Crypto.ensure_user_dek() |> elem(1)

      result = MasterRotation.enqueue_all(2, batch_size: 2)

      assert result.enqueued >= 3

      assert_enqueued(
        worker: RotateUserMasterKey,
        args: %{"target_version" => 2}
      )
    end

    test "skips users already at target on enqueue (no jobs created)" do
      MasterRotation.rotate_all(2)

      result = MasterRotation.enqueue_all(2)
      assert result.enqueued == 0
    end
  end
end
