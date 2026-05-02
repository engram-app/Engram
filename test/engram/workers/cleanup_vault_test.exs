defmodule Engram.Workers.CleanupVaultTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import ExUnit.CaptureLog

  alias Engram.Attachments.Attachment
  alias Engram.Notes.{Chunk, Note}
  alias Engram.Repo
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
      vault = insert(:vault, user: user, deleted_at: DateTime.utc_now())
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
      vault = insert(:vault, user: user, deleted_at: DateTime.utc_now())
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

      log =
        capture_log(fn ->
          assert :ok = CleanupVault.perform_cleanup(vault.id, user.id)
        end)

      # storage_key "test/blob.png" is invalid format → raises ArgumentError
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
end
