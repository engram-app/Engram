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
    test "enqueues repath + link-rewrite jobs in two bulk inserts, one job each per note", ctx do
      %{user: user, vault: vault} = ctx
      notes = seed(user, vault, "Docs")
      ids = notes |> Enum.map(& &1.id) |> Enum.sort()

      {{:ok, _}, inserts} =
        ObanInsertCount.count(fn -> Notes.rename_folder(user, vault, "Docs", "Archive") end)

      # Per-note inserts would be 2 * @n.
      assert inserts <= 2
      assert job_note_ids(RepathNoteIndex) == ids

      rewrites = all_enqueued(worker: RewriteNoteLinks)
      assert rewrites |> Enum.map(& &1.args["target_id"]) |> Enum.sort() == ids

      # Debounce kept: repath is scheduled a few seconds out, hmac-only args.
      for job <- all_enqueued(worker: RepathNoteIndex) do
        assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt
        assert is_binary(job.args["old_path_hmac"])
      end
    end

    test "a note with a pending repath job is not queued a second one", ctx do
      %{user: user, vault: vault} = ctx
      seed(user, vault, "Docs")

      {:ok, _} = Notes.rename_folder(user, vault, "Docs", "Archive")
      {:ok, _} = Notes.rename_folder(user, vault, "Archive", "Docs")

      # The first job reads the note's current path when it runs, so it covers
      # the second rename (this is what the worker's `unique` did).
      assert length(all_enqueued(worker: RepathNoteIndex)) == @n
      # RewriteNoteLinks has no `unique`: one per real move, both renames.
      assert length(all_enqueued(worker: RewriteNoteLinks)) == 2 * @n
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
