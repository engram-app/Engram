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
      {:ok, vault, _} = Vaults.register_vault(user, "Temp Vault", Ecto.UUID.generate())

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

    # Mirrors the key pass: purge revokes a leveled OAuth grant that, with
    # this vault gone, reaches no LIVE vault (its other listed one was
    # deleted too).
    test "revokes a leveled OAuth grant left reaching no live vault", %{
      bypass: bypass,
      user: user,
      vault: vault
    } do
      stub_qdrant(bypass)
      other = insert(:vault, user: user, deleted_at: DateTime.utc_now(:second))
      client = insert(:oauth_client, kind: "mcp")

      grant =
        insert(:oauth_refresh_token,
          user_id: user.id,
          client_id: client.client_id,
          vault_ids: ["00000000-0000-0000-0000-000000000000"],
          vault_access: %{vault.id => "read", other.id => "read"},
          default_access: "none"
        )

      survivor =
        insert(:oauth_refresh_token,
          user_id: user.id,
          client_id: client.client_id,
          vault_ids: ["00000000-0000-0000-0000-000000000000"],
          vault_access: %{vault.id => "read"},
          default_access: "read"
        )

      assert :ok = CleanupVault.perform_cleanup(vault.id, user.id)

      assert Repo.get(Engram.OAuth.RefreshToken, grant.id, skip_tenant_check: true).revoked_at
      refute Repo.get(Engram.OAuth.RefreshToken, survivor.id, skip_tenant_check: true).revoked_at
    end

    # A pre-levels grant still listing only this vault (soft delete missed
    # it: a row written by a release that predates the narrowing) used to
    # vanish through the scalar column's ON DELETE CASCADE: gone, but never
    # counted and its sockets never kicked. Purge judges it like soft delete.
    test "revokes and kicks a pre-levels grant left reaching nothing", %{
      bypass: bypass,
      user: user,
      vault: vault
    } do
      stub_qdrant(bypass)
      client = insert(:oauth_client, kind: "mcp")

      grant =
        insert(:oauth_refresh_token,
          user_id: user.id,
          client_id: client.client_id,
          vault_id: vault.id,
          vault_ids: [vault.id]
        )

      Phoenix.PubSub.subscribe(Engram.PubSub, "user_socket:#{user.id}")

      assert :ok = CleanupVault.perform_cleanup(vault.id, user.id)

      # Its row then goes with the vault (the cascade), which is revoked too.
      assert Repo.get(Engram.OAuth.RefreshToken, grant.id, skip_tenant_check: true) == nil
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    # `drop_vault_from_grants/2` already kicks the owner for a changed grant
    # (`OAuth.grants_changed/1`); the worker kicks only for revoked keys.
    test "a revoked grant kicks the owner's sockets once", %{
      bypass: bypass,
      user: user,
      vault: vault
    } do
      stub_qdrant(bypass)
      client = insert(:oauth_client, kind: "mcp")

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: vault.id,
        vault_ids: [vault.id]
      )

      Phoenix.PubSub.subscribe(Engram.PubSub, "user_socket:#{user.id}")
      assert :ok = CleanupVault.perform_cleanup(vault.id, user.id)

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 200
    end

    # A purge that revokes a key AND changes a grant kicks the owner once.
    test "revoking a key and a grant together kicks the owner's sockets once", %{
      bypass: bypass,
      user: user,
      vault: vault
    } do
      stub_qdrant(bypass)
      client = insert(:oauth_client, kind: "mcp")

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: vault.id,
        vault_ids: [vault.id]
      )

      {:ok, _raw, key} = Engram.Accounts.create_api_key(user, "one-vault")

      Repo.insert_all("api_key_vaults", [
        %{api_key_id: Ecto.UUID.dump!(key.id), vault_id: Ecto.UUID.dump!(vault.id)}
      ])

      Phoenix.PubSub.subscribe(Engram.PubSub, "user_socket:#{user.id}")
      assert :ok = CleanupVault.perform_cleanup(vault.id, user.id)

      assert Repo.get(Engram.Accounts.ApiKey, key.id, skip_tenant_check: true) == nil
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 200
    end

    test "revoking only a key still kicks the owner's sockets, once", %{
      bypass: bypass,
      user: user,
      vault: vault
    } do
      stub_qdrant(bypass)
      {:ok, _raw, key} = Engram.Accounts.create_api_key(user, "one-vault")

      Repo.insert_all("api_key_vaults", [
        %{api_key_id: Ecto.UUID.dump!(key.id), vault_id: Ecto.UUID.dump!(vault.id)}
      ])

      Phoenix.PubSub.subscribe(Engram.PubSub, "user_socket:#{user.id}")
      assert :ok = CleanupVault.perform_cleanup(vault.id, user.id)

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 200
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

    # A big vault used to go in ONE transaction: every chunk, note (with its
    # cascades) and attachment under one snapshot, past the checkout timeout,
    # rolled back and retried forever (2026-10-20 audit, P1-8). Rows now go in
    # id-ordered batches, each committed with its share of the counter, so a
    # retry resumes from what is left.
    test "deletes a vault bigger than one batch, a batch per transaction", %{
      bypass: bypass,
      user: user,
      vault: vault
    } do
      stub_qdrant(bypass)
      Application.put_env(:engram, :cleanup_vault_batch_size, 2)
      on_exit(fn -> Application.delete_env(:engram, :cleanup_vault_batch_size) end)

      notes = for _ <- 1..4, do: insert(:note, user: user, vault: vault)
      insert(:note, user: user, vault: vault, deleted_at: DateTime.utc_now())
      for _ <- 1..3, do: insert(:attachment, user: user, vault: vault)

      for n <- notes do
        %Chunk{
          note_id: n.id,
          vault_id: vault.id,
          user_id: user.id,
          position: 0,
          char_start: 0,
          char_end: 10,
          qdrant_point_id: Ecto.UUID.generate()
        }
        |> Repo.insert!(skip_tenant_check: true)
      end

      # Setup seeded one live note too: 5 live.
      assert UsageMeters.recount_notes!(user.id) == 5

      {:ok, rows} = Repo.with_tenant(user.id, fn -> Repo.aggregate(Note, :count) end)
      assert rows == 6

      {_, queries} =
        Engram.QueryRecorder.record(fn ->
          assert :ok = CleanupVault.perform_cleanup(vault.id, user.id)
        end)

      deleting_notes =
        queries
        |> Engram.QueryRecorder.transactions()
        |> Enum.count(fn stmts -> Enum.any?(stmts, &(&1 =~ ~s(DELETE FROM "notes"))) end)

      # 6 notes at 2 per batch is 3 batches; the final transaction is a 4th.
      assert deleting_notes >= 4, Engram.QueryRecorder.format(queries)

      assert UsageMeters.notes_count(user.id) == 0

      refute Repo.exists?(from(n in Note, where: n.vault_id == ^vault.id),
               skip_tenant_check: true
             )

      refute Repo.exists?(from(a in Attachment, where: a.vault_id == ^vault.id),
               skip_tenant_check: true
             )

      refute Repo.exists?(from(c in Chunk, where: c.vault_id == ^vault.id),
               skip_tenant_check: true
             )

      refute Repo.get(Vault, vault.id, skip_tenant_check: true)
    end

    # A restore committing between two batches must stop the purge: the
    # remaining batches and the final vault delete would otherwise wipe a vault
    # the user has taken back. The restore is injected right after the first
    # note batch's DELETE, so it commits with that batch.
    test "a restore between batches stops the purge and keeps the vault", %{
      bypass: bypass,
      user: user,
      vault: vault
    } do
      stub_qdrant(bypass)
      Application.put_env(:engram, :cleanup_vault_batch_size, 2)
      on_exit(fn -> Application.delete_env(:engram, :cleanup_vault_batch_size) end)
      for _ <- 1..4, do: insert(:note, user: user, vault: vault)

      test_pid = self()
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:engram, :repo, :query],
        fn _e, _m, %{query: sql}, _c ->
          if self() == test_pid and sql =~ ~s(DELETE FROM "notes") do
            :telemetry.detach(handler)

            Repo.update_all(from(v in Vault, where: v.id == ^vault.id), [set: [deleted_at: nil]],
              skip_tenant_check: true
            )
          end
        end,
        nil
      )

      try do
        capture_log(fn -> assert :ok = CleanupVault.perform_cleanup(vault.id, user.id) end)
      after
        :telemetry.detach(handler)
      end

      assert Repo.get(Vault, vault.id, skip_tenant_check: true)

      left =
        Repo.aggregate(from(n in Note, where: n.vault_id == ^vault.id), :count,
          skip_tenant_check: true
        )

      # 5 notes (setup's + 4); one batch of 2 went before the restore.
      assert left == 3
    end

    # A purge that dies mid-way (all attempts) leaves the vault soft-deleted
    # with some of its rows gone. Restoring it would hand back a partial vault
    # as if it were whole, so once the first batch runs the vault is stamped
    # `purge_started_at` and `restore_vault/2` refuses it. A retry finishes.
    test "a purge that fails mid-way leaves the vault unrestorable; a retry finishes", %{
      bypass: bypass,
      user: user,
      vault: vault
    } do
      stub_qdrant(bypass)
      Application.put_env(:engram, :cleanup_vault_batch_size, 2)
      on_exit(fn -> Application.delete_env(:engram, :cleanup_vault_batch_size) end)
      for _ <- 1..4, do: insert(:note, user: user, vault: vault)

      test_pid = self()
      handler = {__MODULE__, make_ref()}
      seen = :counters.new(1, [])

      # The SECOND note batch's DELETE aborts its transaction (a failing
      # statement inside it), so the next statement raises: the first batch
      # is committed, the rest is not.
      :telemetry.attach(
        handler,
        [:engram, :repo, :query],
        fn _e, _m, %{query: sql}, _c ->
          if self() == test_pid and sql =~ ~s(DELETE FROM "notes") do
            :counters.add(seen, 1, 1)

            if :counters.get(seen, 1) == 2 do
              :telemetry.detach(handler)
              Repo.query("SELECT 1/0")
            end
          end
        end,
        nil
      )

      try do
        assert_raise Postgrex.Error, fn -> CleanupVault.perform_cleanup(vault.id, user.id) end
      after
        :telemetry.detach(handler)
      end

      stamped = Repo.get!(Vault, vault.id, skip_tenant_check: true)
      assert stamped.deleted_at
      assert stamped.purge_started_at

      left =
        Repo.aggregate(from(n in Note, where: n.vault_id == ^vault.id), :count,
          skip_tenant_check: true
        )

      # 5 notes (setup's + 4); the first batch of 2 committed.
      assert left == 3

      assert {:error, :purge_started} = Vaults.restore_vault(user, vault.id)
      assert Repo.get!(Vault, vault.id, skip_tenant_check: true).deleted_at

      assert :ok = CleanupVault.perform_cleanup(vault.id, user.id)
      refute Repo.get(Vault, vault.id, skip_tenant_check: true)
    end

    test "a vault whose purge has not started still restores", %{user: user, vault: vault} do
      assert {:ok, restored} = Vaults.restore_vault(user, vault.id)
      assert restored.id == vault.id
      refute Repo.get!(Vault, vault.id, skip_tenant_check: true).deleted_at
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

    test "discards and preserves the vault when the job's user_id does not own it", %{
      vault: vault,
      note: note
    } do
      # No Qdrant stub: an owner-mismatch must bail out before any destructive
      # work, so the worker must never reach the Qdrant delete.
      log =
        capture_log(fn ->
          assert {:discard, :owner_mismatch} =
                   CleanupVault.perform_cleanup(vault.id, Ecto.UUID.generate())
        end)

      assert log =~ "owner mismatch"
      # Tenant data untouched.
      assert Repo.get(Note, note.id, skip_tenant_check: true)
      assert Repo.get(Vault, vault.id, skip_tenant_check: true)
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
      # A real UUID rather than `1`: this test's subject is the missing vault,
      # and job args always carry a uuid user_id. The tenant-scoped load now
      # rejects a non-uuid outright, so the literal `1` was testing the
      # argument type by accident.
      assert :ok =
               CleanupVault.perform_cleanup(
                 "00000000-0000-0000-0000-000000999999",
                 Ecto.UUID.generate()
               )
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
      {:ok, v, _} = Vaults.register_vault(user, "V", Ecto.UUID.generate())
      assert :ok = CleanupVault.perform_cleanup(v.id, user.id)
      assert Repo.get(Vault, v.id, skip_tenant_check: true)
    end

    test "snoozes when deleted_at is younger than 30 days", %{user: user} do
      {:ok, v, _} = Vaults.register_vault(user, "V", Ecto.UUID.generate())
      {:ok, _} = Vaults.delete_vault(user, v.id)
      backdate_deleted_at(v.id, 5)

      assert {:snooze, secs} = CleanupVault.perform_cleanup(v.id, user.id)
      assert secs > 0
      assert Repo.get(Vault, v.id, skip_tenant_check: true)
    end

    test "purges when deleted_at is older than 30 days", %{bypass: bypass, user: user} do
      stub_qdrant_ack(bypass)
      {:ok, v, _} = Vaults.register_vault(user, "V", Ecto.UUID.generate())
      {:ok, _} = Vaults.delete_vault(user, v.id)
      backdate_deleted_at(v.id, 31)

      assert :ok = CleanupVault.perform_cleanup(v.id, user.id)
      refute Repo.get(Vault, v.id, skip_tenant_check: true)
    end

    test "force purges immediately regardless of age", %{bypass: bypass, user: user} do
      stub_qdrant_ack(bypass)
      {:ok, v, _} = Vaults.register_vault(user, "V", Ecto.UUID.generate())
      {:ok, _} = Vaults.delete_vault(user, v.id)
      # freshly deleted (age ~0) but force=true

      assert :ok = CleanupVault.perform_cleanup(v.id, user.id, force: true)
      refute Repo.get(Vault, v.id, skip_tenant_check: true)
    end
  end
end
