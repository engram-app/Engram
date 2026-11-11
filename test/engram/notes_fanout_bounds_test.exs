defmodule Engram.NotesFanoutBoundsTest do
  # #2169: a cascade over N notes must cost O(N / chunk) Oban insert
  # statements, not O(N). The count is the `INSERT INTO "oban_jobs"` statements
  # the calling process issues; each is one pool checkout.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.{Folders, Notes, ObanInsertCount, Repo}

  alias Engram.Workers.{
    DeleteNoteIndex,
    EmbedNote,
    ExtractNoteLinks,
    RepathNoteIndex,
    RewriteNoteLinks
  }

  @n 8

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp seed(user, vault, folder, n \\ @n) do
    for i <- 1..n do
      {:ok, note} =
        Notes.upsert_note(
          user,
          vault,
          %{"path" => "#{folder}/n#{i}.md", "content" => "body #{i}", "mtime" => 1.0},
          actor: "api"
        )

      note
    end
  end

  defp job_note_ids(worker),
    do: [worker: worker] |> all_enqueued() |> Enum.map(& &1.args["note_id"]) |> Enum.sort()

  describe "delete_scanned/4 (folder delete cascade)" do
    test "enqueues the index cleanup in one bulk insert, one job per note", ctx do
      %{user: user, vault: vault} = ctx
      notes = seed(user, vault, "Docs")
      {:ok, matches} = Notes.scan_folders(user, vault, ["Docs"])

      {{:ok, %{notes: @n}}, inserts} =
        ObanInsertCount.count(fn -> Notes.delete_scanned(user, vault, matches) end)

      # ReleaseIndexEntries.enqueue is one more insert; the cleanup jobs are
      # one. Per-note inserts would be at least @n.
      assert inserts <= 2
      assert job_note_ids(DeleteNoteIndex) == notes |> Enum.map(& &1.id) |> Enum.sort()
    end
  end

  describe "rename_folder/4 (folder rename cascade)" do
    # Every moved row is re-encrypted (path + folder envelopes, plus a
    # tombstone each). That CPU used to run AFTER next_seq! took the vault
    # row lock, so a big folder rename stalled every other writer of the
    # vault. (Call tracing cannot see it: crypto marks the process
    # :sensitive, which silences trace messages by design.)
    test "re-encrypts the moved notes before opening the write transaction", ctx do
      %{user: user, vault: vault} = ctx
      seed(user, vault, "Docs")
      test = self()

      Application.put_env(:engram, :checkpoint_interleave_hook, fn
        :folder_rename_seal -> send(test, {:sealed_in_txn, Repo.in_transaction?()})
        _ -> :ok
      end)

      on_exit(fn -> Application.delete_env(:engram, :checkpoint_interleave_hook) end)

      assert {:ok, _} = Notes.rename_folder(user, vault, "Docs", "Archive")
      assert_received {:sealed_in_txn, false}
    end

    # The fan-out is an outbox: it commits with the rows it covers, so a
    # crash between the commit and a separate enqueue cannot lose a rewrite.
    test "the link-rewrite jobs insert inside the rename transaction", ctx do
      %{user: user, vault: vault} = ctx
      seed(user, vault, "Docs")

      {{:ok, _}, queries} =
        Engram.QueryRecorder.record(fn -> Notes.rename_folder(user, vault, "Docs", "Archive") end)

      txns = Engram.QueryRecorder.transactions(queries)

      [rename_txn] =
        Enum.filter(txns, fn stmts -> Enum.any?(stmts, &(&1 =~ "SET change_seq")) end)

      assert Enum.any?(rename_txn, &(&1 =~ ~r/^INSERT INTO .*oban_jobs/))
    end

    # Folders.rename/4 runs the cascade inside its own transaction, which holds
    # the vault row lock until it commits. The broadcast needs every renamed
    # note's content decrypted; read inside that transaction, the decrypt held
    # the lock too. It runs after the commit.
    test "under Folders.rename the content read for the broadcast runs after commit", ctx do
      %{user: user, vault: vault} = ctx
      seed(user, vault, "Docs")
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      {{:ok, _}, queries} =
        Engram.QueryRecorder.record(fn -> Folders.rename(user, vault, "Docs", "Archive") end)

      [rename_txn] =
        queries
        |> Engram.QueryRecorder.transactions()
        |> Enum.filter(fn stmts -> Enum.any?(stmts, &(&1 =~ "SET change_seq")) end)

      refute Enum.any?(rename_txn, &(&1 =~ ~r/^SELECT .*content_ciphertext/)),
             "content decrypted under the vault lock"

      # The broadcast still ships the body inline (e2e test_34).
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "note_changed",
                       payload: %{"event_type" => "upsert", "content" => "body " <> _}
                     },
                     1_000
    end

    test "enqueues the link-rewrite jobs in one bulk insert, one per note; no index job",
         ctx do
      %{user: user, vault: vault} = ctx
      notes = seed(user, vault, "Docs")
      ids = notes |> Enum.map(& &1.id) |> Enum.sort()

      {{:ok, _}, inserts} =
        ObanInsertCount.count(fn -> Notes.rename_folder(user, vault, "Docs", "Archive") end)

      # Per-note inserts would be @n.
      assert inserts <= 1

      rewrites = all_enqueued(worker: RewriteNoteLinks)
      assert rewrites |> Enum.map(& &1.args["target_id"]) |> Enum.sort() == ids
      # R3a: a move makes no Qdrant write.
      assert all_enqueued(worker: RepathNoteIndex) == []
    end
  end

  describe "Enqueue.enqueue_all/2 and Jobs.insert_chunked/1" do
    test "a chunk that keeps failing is logged with telemetry, not raised" do
      test = self()
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:engram, :notes, :enqueue, :failed],
        fn _, m, meta, _ -> send(test, {:failed, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = Engram.Notes.Enqueue.enqueue_all([:not_a_changeset], "probe")
      end)

      assert_received {:failed, %{count: 1}, %{worker: "probe"}}
    end

    test "inserts past the chunk size take one statement per chunk" do
      n = Engram.Batch.insert_rows() + 1

      jobs =
        for _ <- 1..n do
          DeleteNoteIndex.new(%{
            note_id: Ecto.UUID.generate(),
            user_id: Ecto.UUID.generate(),
            vault_id: Ecto.UUID.generate(),
            path_hmac: "x"
          })
        end

      assert {^n, 2} = ObanInsertCount.count(fn -> Engram.Jobs.insert_chunked(jobs) end)
    end
  end

  describe "restore_op/3 (undo of a folder delete)" do
    test "queues embed + link jobs for the chunk in bulk, one of each per note", ctx do
      %{user: user, vault: vault} = ctx
      notes = seed(user, vault, "Docs")
      ids = notes |> Enum.map(& &1.id) |> Enum.sort()
      op = Ecto.UUID.generate()

      {:ok, %{notes: @n}} = Folders.delete(user, vault, "Docs", recursive: true, op_id: op)

      # Drop what the original writes queued, so only the restore's show.
      Repo.delete_all(
        from(j in Oban.Job,
          where: j.worker in ["Engram.Workers.EmbedNote", "Engram.Workers.ExtractNoteLinks"]
        )
      )

      {{:ok, %{notes: @n}}, inserts} =
        ObanInsertCount.count(fn -> Folders.restore_op(user, vault, op) end)

      # Per-row enqueue was 2 * @n; the rest is the claim release.
      assert inserts <= 3
      assert job_note_ids(EmbedNote) == ids
      assert job_note_ids(ExtractNoteLinks) == ids
      # Never embedded since the delete, so backfill priority, as before.
      assert Enum.all?(all_enqueued(worker: EmbedNote), &(&1.priority == 9))
    end

    test "a note with a pending embed job is promoted, not duplicated", ctx do
      %{user: user, vault: vault} = ctx
      notes = seed(user, vault, "Docs", 2)
      op = Ecto.UUID.generate()
      {:ok, _} = Folders.delete(user, vault, "Docs", recursive: true, op_id: op)

      Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.EmbedNote"))
      [first | _] = notes
      {:ok, _} = Oban.insert(EmbedNote.new_debounced(first.id, user.id, priority: 9))

      {:ok, _} = Folders.restore_op(user, vault, op)

      jobs = all_enqueued(worker: EmbedNote)
      assert length(jobs) == 2

      assert jobs |> Enum.map(& &1.args["note_id"]) |> Enum.sort() ==
               notes |> Enum.map(& &1.id) |> Enum.sort()
    end
  end
end
