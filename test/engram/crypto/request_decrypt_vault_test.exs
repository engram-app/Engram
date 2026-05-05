defmodule Engram.Crypto.RequestDecryptVaultTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Crypto
  alias Engram.Vaults.Vault
  alias Engram.Workers.DecryptVault
  alias Engram.Repo

  setup do
    user = insert(:user, encryption_toggle_cooldown_days: 7)
    old = DateTime.utc_now() |> DateTime.add(-8, :day)

    vault =
      insert(:vault,
        user: user,
        encrypted: true,
        encryption_status: "encrypted",
        encrypted_at: old,
        last_toggle_at: old
      )

    %{user: user, vault: vault}
  end

  describe "request_decrypt_vault/2" do
    test "flips vault to decrypt_pending and schedules DecryptVault at +24h", %{
      user: user,
      vault: vault
    } do
      assert {:ok, updated} = Crypto.request_decrypt_vault(vault, user)
      assert updated.encryption_status == "decrypt_pending"
      assert updated.decrypt_requested_at != nil
      assert updated.last_toggle_at != nil
      assert DateTime.diff(updated.last_toggle_at, vault.last_toggle_at, :second) > 0

      job = all_enqueued(worker: DecryptVault) |> List.first()
      refute is_nil(job)
      assert job.args == %{"vault_id" => vault.id, "user_id" => user.id, "cursor" => 0}
      diff_seconds = DateTime.diff(job.scheduled_at, DateTime.utc_now(), :second)
      assert diff_seconds > 23 * 3600 and diff_seconds <= 24 * 3600
    end

    test "returns :bad_status when not encrypted", %{user: user, vault: vault} do
      {:ok, vault} = Vault.update_status(vault, "none")
      assert {:error, :bad_status} = Crypto.request_decrypt_vault(vault, user)
    end

    test "returns :cooldown when last_toggle_at within configured cooldown", %{
      user: user,
      vault: vault
    } do
      recent = DateTime.utc_now() |> DateTime.add(-3, :day)
      {:ok, vault} = vault |> Ecto.Changeset.change(%{last_toggle_at: recent}) |> Repo.update()
      assert {:error, :cooldown} = Crypto.request_decrypt_vault(vault, user)
    end

    test "skips cooldown when user.encryption_toggle_cooldown_days is NULL", %{
      user: user,
      vault: vault
    } do
      {:ok, user} =
        user |> Ecto.Changeset.change(%{encryption_toggle_cooldown_days: nil}) |> Repo.update()

      recent = DateTime.utc_now() |> DateTime.add(-1, :day)
      {:ok, vault} = vault |> Ecto.Changeset.change(%{last_toggle_at: recent}) |> Repo.update()
      assert {:ok, _} = Crypto.request_decrypt_vault(vault, user)
    end

    test "emits :decrypt_requested telemetry", %{user: user, vault: vault} do
      :telemetry.attach(
        "test-decrypt-requested",
        [:engram, :crypto, :decrypt_requested],
        fn _name, _measurements, meta, _config ->
          send(self(), {:telemetry, meta})
        end,
        nil
      )

      {:ok, _} = Crypto.request_decrypt_vault(vault, user)
      assert_receive {:telemetry, %{vault_id: id, user_id: uid}}, 100
      assert id == vault.id
      assert uid == user.id

      :telemetry.detach("test-decrypt-requested")
    end
  end
end
