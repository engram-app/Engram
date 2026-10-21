defmodule Engram.Crypto.RotationGateTest do
  use Engram.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts.User
  alias Engram.Crypto.RotationGate
  alias Engram.Repo

  setup do
    user = insert(:user)
    {:ok, user: user}
  end

  # ---------------------------------------------------------------------------
  # check/1 — re-reads the user row for fresh lock state
  # ---------------------------------------------------------------------------

  describe "check/1" do
    test "returns :ok when user exists and is not locked", %{user: user} do
      assert :ok = RotationGate.check(user.id)
    end

    test "returns {:error, :rotation_in_progress} when user is locked", %{user: user} do
      lock_user!(user.id)
      assert {:error, :rotation_in_progress} = RotationGate.check(user.id)
    end

    test "returns :ok after lock is released", %{user: user} do
      lock_user!(user.id)
      assert {:error, :rotation_in_progress} = RotationGate.check(user.id)

      unlock_user!(user.id)
      assert :ok = RotationGate.check(user.id)
    end

    test "returns {:error, :user_not_found} when user does not exist" do
      # Use an id that cannot exist in the test DB
      assert {:error, :user_not_found} = RotationGate.check(Ecto.UUID.generate())
    end
  end

  # ---------------------------------------------------------------------------
  # gated/1 — the lock read rides on the transaction's own tenant_enter
  # ---------------------------------------------------------------------------

  describe "gated/1" do
    test "a tenant transaction for a locked user raises before fun runs", %{user: user} do
      lock_user!(user.id)

      assert_raise Engram.Crypto.RotationInProgressError, fn ->
        RotationGate.gated(fn ->
          Repo.with_tenant(user.id, fn -> send(self(), :ran) end)
        end)
      end

      refute_received :ran
    end

    test "an unlocked user's transaction runs, in one tenant_enter", %{user: user} do
      {result, queries} =
        Engram.QueryRecorder.record(fn ->
          RotationGate.gated(fn -> Repo.with_tenant(user.id, fn -> :done end) end)
        end)

      assert result == {:ok, :done}
      sources = queries |> Enum.filter(&(&1.pid == self())) |> Enum.map(& &1.source)
      assert Enum.count(sources, &(&1 == "tenant_enter")) == 1
      refute Enum.any?(queries, &(&1.pid == self() and &1.sql =~ ~r/FROM "users"/))
    end

    test "outside gated/1 a locked user's transaction still runs", %{user: user} do
      lock_user!(user.id)
      RotationGate.gated(fn -> :ok end)
      assert {:ok, :done} = Repo.with_tenant(user.id, fn -> :done end)
    end
  end

  # ---------------------------------------------------------------------------
  # check_user/1 — uses the in-memory struct (no DB round-trip)
  # ---------------------------------------------------------------------------

  describe "check_user/1" do
    test "returns :ok when dek_rotation_locked_at is nil" do
      user = %User{dek_rotation_locked_at: nil}
      assert :ok = RotationGate.check_user(user)
    end

    test "returns {:error, :rotation_in_progress} when dek_rotation_locked_at is set" do
      user = %User{dek_rotation_locked_at: DateTime.utc_now()}
      assert {:error, :rotation_in_progress} = RotationGate.check_user(user)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp lock_user!(user_id) do
    Repo.update_all(
      from(u in User, where: u.id == ^user_id),
      [set: [dek_rotation_locked_at: DateTime.utc_now()]],
      skip_tenant_check: true
    )
  end

  defp unlock_user!(user_id) do
    Repo.update_all(
      from(u in User, where: u.id == ^user_id),
      [set: [dek_rotation_locked_at: nil]],
      skip_tenant_check: true
    )
  end
end
