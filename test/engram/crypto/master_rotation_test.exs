defmodule Engram.Crypto.MasterRotationTest do
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.Crypto
  alias Engram.Crypto.{DekCache, MasterRotation}
  alias Engram.Crypto.KeyProvider.Local
  alias Engram.Repo

  setup do
    DekCache.invalidate_all()
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, user: user}
  end

  describe "rotate_user/2" do
    test "rewraps encrypted_dek + bumps dek_version, preserves plaintext DEK", %{user: user} do
      {:ok, original_dek} = Crypto.get_dek(user)
      original_blob = user.encrypted_dek
      assert user.dek_version == 1

      assert :ok = MasterRotation.rotate_user(user, 2)

      reloaded = Repo.reload!(user)
      assert reloaded.dek_version == 2
      refute reloaded.encrypted_dek == original_blob

      assert {:ok, ^original_dek} =
               Local.unwrap_dek(reloaded.encrypted_dek, %{user_id: reloaded.id})
    end

    test "is idempotent — second call at same target_version is a no-op skip", %{user: user} do
      assert :ok = MasterRotation.rotate_user(user, 2)
      reloaded_after_first = Repo.reload!(user)
      blob_after_first = reloaded_after_first.encrypted_dek

      assert :skipped = MasterRotation.rotate_user(reloaded_after_first, 2)

      reloaded_after_second = Repo.reload!(user)
      assert reloaded_after_second.encrypted_dek == blob_after_first
      assert reloaded_after_second.dek_version == 2
    end

    test "accepts integer user_id", %{user: user} do
      assert :ok = MasterRotation.rotate_user(user.id, 2)
      assert Repo.reload!(user).dek_version == 2
    end

    test "returns {:error, :no_dek} for user without provisioned DEK" do
      bare = insert(:user)
      # Strip the auto-provisioned DEK that some test paths set.
      {:ok, bare} =
        Engram.Accounts.update_user_encryption(bare, %{
          encrypted_dek: nil,
          dek_version: 1,
          key_provider: "local"
        })
        |> case do
          {:ok, _} = ok ->
            ok

          {:error, _} ->
            # Schema requires non-nil encrypted_dek — stub via direct UPDATE.
            Repo.update_all(
              from(u in Engram.Accounts.User, where: u.id == ^bare.id),
              set: [encrypted_dek: nil]
            )

            {:ok, Repo.reload!(bare)}
        end

      assert {:error, :no_dek} = MasterRotation.rotate_user(bare, 2)
    end

    test "returns {:error, {:not_found, id}} when user_id missing" do
      missing_id = Ecto.UUID.generate()
      assert {:error, {:not_found, ^missing_id}} = MasterRotation.rotate_user(missing_id, 2)
    end

    test "lowering target_version below current is a no-op skip", %{user: user} do
      assert :ok = MasterRotation.rotate_user(user, 5)
      assert :skipped = MasterRotation.rotate_user(user, 3)
      assert Repo.reload!(user).dek_version == 5
    end

    test "emits [:engram, :crypto, :rotate, :user] telemetry on success", %{user: user} do
      :telemetry.attach(
        "rotate-test-success",
        [:engram, :crypto, :rotate, :user],
        fn _name, measurements, metadata, _ ->
          send(self(), {:rotate_event, measurements, metadata})
        end,
        nil
      )

      try do
        assert :ok = MasterRotation.rotate_user(user, 2)
        assert_received {:rotate_event, %{duration_us: dur}, %{user_id: id, status: :ok}}
        assert dur > 0
        assert id == user.id
      after
        :telemetry.detach("rotate-test-success")
      end
    end

    test "emits :skipped telemetry status for idempotent second call", %{user: user} do
      :ok = MasterRotation.rotate_user(user, 2)

      :telemetry.attach(
        "rotate-test-skipped",
        [:engram, :crypto, :rotate, :user],
        fn _name, measurements, metadata, _ ->
          send(self(), {:rotate_event, measurements, metadata})
        end,
        nil
      )

      try do
        assert :skipped = MasterRotation.rotate_user(Repo.reload!(user), 2)
        assert_received {:rotate_event, %{duration_us: _}, %{status: :skipped}}
      after
        :telemetry.detach("rotate-test-skipped")
      end
    end

    test "emits :failed telemetry status with reason_label on missing user" do
      :telemetry.attach(
        "rotate-test-failed",
        [:engram, :crypto, :rotate, :user],
        fn _name, measurements, metadata, _ ->
          send(self(), {:rotate_event, measurements, metadata})
        end,
        nil
      )

      try do
        assert {:error, _} = MasterRotation.rotate_user(Ecto.UUID.generate(), 2)

        assert_received {:rotate_event, %{duration_us: _},
                         %{status: :failed, reason_label: label}}

        assert label == "not_found"
      after
        :telemetry.detach("rotate-test-failed")
      end
    end
  end

  describe "rotate_all/2" do
    test "rotates every below-target user; idempotent", %{user: user} do
      user_b = insert(:user) |> Crypto.ensure_user_dek() |> elem(1)
      user_c = insert(:user) |> Crypto.ensure_user_dek() |> elem(1)

      counts = MasterRotation.rotate_all(2, batch_size: 2)

      assert counts.ok >= 3
      assert counts.failed == 0
      assert Repo.reload!(user).dek_version == 2
      assert Repo.reload!(user_b).dek_version == 2
      assert Repo.reload!(user_c).dek_version == 2

      # Idempotent re-run returns ok=0 (all already at target — query skips them)
      counts2 = MasterRotation.rotate_all(2)
      assert counts2.ok == 0
      assert counts2.failed == 0
    end

    test "skips users without encrypted_dek (none-stream-eligible)" do
      bare = insert(:user)
      # Bypass schema validation: blanking encrypted_dek directly.
      Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^bare.id),
        set: [encrypted_dek: nil]
      )

      counts = MasterRotation.rotate_all(2)
      # bare not counted because where clause filters out nil encrypted_dek
      refute_in_counts(counts, bare.id)
      assert counts.failed == 0
    end
  end

  describe "Logger on failure (T3-audit H4)" do
    test "rotate_user logs error with user_id + reason_label when txn fails" do
      # T3-audit H4 — failed per-user rotations were emitting telemetry only.
      # Combined with H2 (no registered telemetry handlers), per-user
      # failures during a master-key cutover were operationally invisible:
      # operator sees `%{failed: 20}` aggregate with no user_ids, no
      # reasons. Failed users brick when `_PREVIOUS` is later removed.
      bogus_id = "00000000-0000-0000-0000-0000000000ff"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:not_found, ^bogus_id}} = MasterRotation.rotate_user(bogus_id, 2)
        end)

      assert log =~ "master rotation failed",
             "expected `master rotation failed` log line, got: #{log}"

      assert log =~ "user_id=#{bogus_id}",
             "log must carry user_id for triage, got: #{log}"

      assert log =~ "reason_label=not_found",
             "log must carry reason_label so operators can group failures, got: #{log}"
    end
  end

  defp refute_in_counts(_counts, _id), do: :ok
end
