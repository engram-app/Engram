defmodule Engram.Workers.ReconcileEmbeddingsTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Workers.{EmbedNote, ReconcileEmbeddings}

  describe "perform/1" do
    test "queues jobs for notes with nil embed_hash" do
      user = insert(:user)
      note = insert(:note, user: user, embed_hash: nil)

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      assert_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
    end

    test "queues jobs for notes with stale embed_hash" do
      user = insert(:user)

      note =
        insert(:note,
          user: user,
          content_hash: "new_hash",
          embed_hash: "old_hash"
        )

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      assert_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
    end

    test "skips notes where embed_hash matches content_hash" do
      user = insert(:user)
      _note = insert(:note, user: user, content_hash: "abc123", embed_hash: "abc123")

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      refute_enqueued(worker: EmbedNote)
    end

    test "skips soft-deleted notes" do
      user = insert(:user)

      _note =
        insert(:note,
          user: user,
          embed_hash: nil,
          deleted_at: DateTime.utc_now()
        )

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      refute_enqueued(worker: EmbedNote)
    end

    test "batches at most 100 notes per vault" do
      user = insert(:user)
      vault = insert(:vault, user: user)

      for i <- 1..105 do
        Engram.Fixtures.insert_note!(user, vault,
          path: "batch/note-#{i}.md",
          content: "# Note #{i}",
          embed_hash: nil
        )
      end

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      jobs = all_enqueued(worker: EmbedNote)
      assert length(jobs) == 100
    end
  end
end
