defmodule Engram.Workers.CleanupVaultTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import ExUnit.CaptureLog
  import Mox

  setup :set_mox_from_context
  setup :verify_on_exit!

  alias Engram.Attachments.Attachment
  alias Engram.Notes.{Chunk, Note}
  alias Engram.Repo
  alias Engram.UsageMeters
  alias Engram.Vaults
  alias Engram.Vaults.Vault
  alias Engram.Workers.CleanupVault

  # ---------------------------------------------------------------------------
  # enqueue/2
  # ---------------------------------------------------------------------------

  describe "enqueue/2" do
    test "inserts an Oban job scheduled 30 days out" do
      user = insert(:user)
      vault = insert(:vault, user: user)

      assert {:ok, job} = CleanupVault.enqueue(vault.id, user.id)

      assert job.worker == "Engram.Workers.CleanupVault"
      assert job.args == %{vault_id: vault.id, user_id: user.id}
      assert job.queue == "cleanup"

      # Scheduled 30 days out (allow a few seconds of clock drift)
      now = DateTime.utc_now()
      diff = DateTime.diff(job.scheduled_at, now, :second)
      assert diff >= 30 * 24 * 60 * 60 - 5
      assert diff <= 30 * 24 * 60 * 60 + 5
    end

    test "enqueue/2 is called when delete_vault soft-deletes" do
      user = insert(:user)
      {:ok, vault} = Vaults.create_vault(user, %{name: "Temp Vault"})

      assert {:ok, _deleted} = Vaults.delete_vault(user, vault.id)

      assert_enqueued(worker: CleanupVault, args: %{"vault_id" => vault.id, "user_id" => user.id})
    end
  end

  # ---------------------------------------------------------------------------
  # perform_cleanup/2 — success path
  # ---------------------------------------------------------------------------

  describe "perform_cleanup/2 — hard-delete" do
    setup do
      bypass = Bypass.open()
      Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
      on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

      user = insert(:user)
      # Aged past the 30-day retention window so perform_cleanup hard-deletes
      # rather than snoozing on the age guard.
      vault =
        insert(:vault,
          user: user,
          deleted_at: DateTime.add(DateTime.utc_now(), -31, :day) |> DateTime.truncate(:second)
        )

      note = insert(:note, user: user, vault: vault)
      attachment = insert(:attachment, user: user, vault: vault)

      %{bypass: bypass, user: user, vault: vault, note: note, attachment: attachment}
    end

    defp stub_qdrant(bypass) do
      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "acknowledged"}}))
      end)
    end

    test "hard-deletes notes, attachments, and vault when soft-deleted", %{
      bypass: bypass,
      user: user,
      vault: vault,
      note: note,
      attachment: attachment
    } do
      stub_qdrant(bypass)

      assert :ok = CleanupVault.perform_cleanup(vault.id, user.id)

      refute Repo.get(Note, note.id, skip_tenant_check: true)
      refute Repo.get(Attachment, attachment.id, skip_tenant_check: true)
      refute Repo.get(Vault, vault.id, skip_tenant_check: true)
    end

    test "decrements the owner's notes_count by the vault's live notes", %{
      bypass: bypass,
      user: user,
      vault: vault
    } do
      stub_qdrant(bypass)

      # A soft-deleted note in the same vault must NOT be double-counted.
      insert(:note, user: user, vault: vault, deleted_at: DateTime.utc_now())

      # Setup seeded one live note; sync the counter to reality.
      assert UsageMeters.recount_notes!(user.id) == 1
      assert UsageMeters.notes_count(user.id) == 1

      assert :ok = CleanupVault.perform_cleanup(vault.id, user.id)

      assert UsageMeters.notes_count(user.id) == 0
    end

    test "hard-deletes chunks associated with notes", %{
      bypass: bypass,
      user: user,
      vault: vault,
      note: note
    } do
      stub_qdrant(bypass)

      # Insert a chunk directly
      chunk =
        %Chunk{
          note_id: note.id,
          vault_id: vault.id,
          user_id: user.id,
          position: 0,
          char_start: 0,
          char_end: 10,
          qdrant_point_id: Ecto.UUID.generate()
        }
        |> Repo.insert!(skip_tenant_check: true)

      assert :ok = CleanupVault.perform_cleanup(vault.id, user.id)

      refute Repo.get(Chunk, chunk.id, skip_tenant_check: true)
    end

    test "Qdrant failure does not prevent DB cleanup", %{
      bypass: bypass,
      user: user,
      vault: vault,
      note: note
    } do
      # Return a 400 (non-transient, won't trigger Req retry backoff)
      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, ~s({"status": "error"}))
      end)

      log =
        capture_log(fn ->
          assert :ok = CleanupVault.perform_cleanup(vault.id, user.id)
        end)

      assert log =~ "Qdrant delete failed"

      # DB cleanup still happened despite Qdrant error
      refute Repo.get(Note, note.id, skip_tenant_check: true)
      refute Repo.get(Vault, vault.id, skip_tenant_check: true)
    end
  end

  # ---------------------------------------------------------------------------
  # perform_cleanup/2 — blob ordering (post-commit)
  # ---------------------------------------------------------------------------

  describe "perform_cleanup/2 — blob deletion ordering" do
    setup do
      bypass = Bypass.open()
      Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
      on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

      user = insert(:user)
      # Aged past the 30-day retention window so perform_cleanup hard-deletes
      # rather than snoozing on the age guard.
      vault =
        insert(:vault,
          user: user,
          deleted_at: DateTime.add(DateTime.utc_now(), -31, :day) |> DateTime.truncate(:second)
        )

      note = insert(:note, user: user, vault: vault)
      attachment = insert(:attachment, user: user, vault: vault, storage_key: "test/blob.png")

      %{bypass: bypass, user: user, vault: vault, note: note, attachment: attachment}
    end

    test "DB rows are deleted even if storage adapter fails", %{
      bypass: bypass,
      user: user,
      vault: vault,
      note: note,
      attachment: attachment
    } do
      # Qdrant succeeds, but we can verify that DB cleanup is not blocked by blob issues
      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "acknowledged"}}))
      end)

      # Swap default InMemory adapter for MockStorage and stub it to raise so the
      # CleanupVault worker exercises its rescue branch (the InMemory adapter's
      # :ets.delete never raises, regardless of key shape).
      prev = Application.get_env(:engram, :storage)
      Application.put_env(:engram, :storage, Engram.MockStorage)
      on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
      stub(Engram.MockStorage, :delete, fn _key -> raise "simulated S3 failure" end)

      log =
        capture_log(fn ->
          assert :ok = CleanupVault.perform_cleanup(vault.id, user.id)
        end)

      assert log =~ "storage delete raised"

      # DB cleanup completed successfully
      refute Repo.get(Note, note.id, skip_tenant_check: true)
      refute Repo.get(Attachment, attachment.id, skip_tenant_check: true)
      refute Repo.get(Vault, vault.id, skip_tenant_check: true)
    end
  end

  # ---------------------------------------------------------------------------
  # perform_cleanup/2 — skip paths
  # ---------------------------------------------------------------------------

  describe "perform_cleanup/2 — skip" do
    test "skips when vault doesn't exist" do
      assert :ok = CleanupVault.perform_cleanup(999_999, 1)
    end

    test "skips when vault is not soft-deleted (was restored)" do
      user = insert(:user)
      vault = insert(:vault, user: user, deleted_at: nil)

      assert :ok = CleanupVault.perform_cleanup(vault.id, user.id)

      # Vault still exists
      assert Repo.get(Vault, vault.id, skip_tenant_check: true)
    end
  end

  # ---------------------------------------------------------------------------
  # perform_cleanup/3 — retention age guard + force purge
  # ---------------------------------------------------------------------------

  describe "perform_cleanup/3 — age guard" do
    setup do
      bypass = Bypass.open()
      Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
      on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

      user = insert(:user)
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      %{bypass: bypass, user: user}
    end

    defp stub_qdrant_ack(bypass) do
      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "acknowledged"}}))
      end)
    end

    defp backdate_deleted_at(vault_id, days) do
      ts =
        DateTime.utc_now()
        |> DateTime.add(-days * 86_400, :second)
        |> DateTime.truncate(:second)

      from(v in Vault, where: v.id == ^vault_id)
      |> Repo.update_all([set: [deleted_at: ts]], skip_tenant_check: true)
    end

    test "skips when the vault was restored (deleted_at nil)", %{user: user} do
      {:ok, v} = Vaults.create_vault(user, %{name: "V"})
      assert :ok = CleanupVault.perform_cleanup(v.id, user.id)
      assert Repo.get(Vault, v.id, skip_tenant_check: true)
    end

    test "snoozes when deleted_at is younger than 30 days", %{user: user} do
      {:ok, v} = Vaults.create_vault(user, %{name: "V"})
      {:ok, _} = Vaults.delete_vault(user, v.id)
      backdate_deleted_at(v.id, 5)

      assert {:snooze, secs} = CleanupVault.perform_cleanup(v.id, user.id)
      assert secs > 0
      assert Repo.get(Vault, v.id, skip_tenant_check: true)
    end

    test "purges when deleted_at is older than 30 days", %{bypass: bypass, user: user} do
      stub_qdrant_ack(bypass)
      {:ok, v} = Vaults.create_vault(user, %{name: "V"})
      {:ok, _} = Vaults.delete_vault(user, v.id)
      backdate_deleted_at(v.id, 31)

      assert :ok = CleanupVault.perform_cleanup(v.id, user.id)
      refute Repo.get(Vault, v.id, skip_tenant_check: true)
    end

    test "force purges immediately regardless of age", %{bypass: bypass, user: user} do
      stub_qdrant_ack(bypass)
      {:ok, v} = Vaults.create_vault(user, %{name: "V"})
      {:ok, _} = Vaults.delete_vault(user, v.id)
      # freshly deleted (age ~0) but force=true

      assert :ok = CleanupVault.perform_cleanup(v.id, user.id, force: true)
      refute Repo.get(Vault, v.id, skip_tenant_check: true)
    end
  end
end
