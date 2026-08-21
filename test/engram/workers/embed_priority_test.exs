defmodule Engram.Workers.EmbedPriorityTest do
  use Engram.DataCase, async: true

  alias Engram.Notes.Note
  alias Engram.Workers.EmbedNote

  describe "priority_for/1" do
    test "a never-embedded note is backfill priority" do
      assert EmbedNote.priority_for(%Note{embed_hash: nil}) == EmbedNote.backfill_priority()
    end

    test "a previously-embedded note is interactive priority 0" do
      assert EmbedNote.priority_for(%Note{embed_hash: "abc123"}) == 0
    end

    test "backfill priority is strictly lower than interactive" do
      # Oban fetches ascending: a LOWER number wins. This is the whole point —
      # a live edit must be able to jump a bulk import's backlog.
      assert EmbedNote.backfill_priority() > 0
    end

    test "backfill priority satisfies the oban_jobs non_negative_priority check" do
      assert EmbedNote.backfill_priority() >= 0
      # Oban's schema caps usable priority at 9.
      assert EmbedNote.backfill_priority() <= 9
    end
  end

  describe "new_debounced/2 priority" do
    test "defaults to interactive priority" do
      changeset = EmbedNote.new_debounced(Ecto.UUID.generate())
      assert Ecto.Changeset.get_field(changeset, :priority) == 0
    end

    test "carries an explicit priority through to the job" do
      changeset =
        EmbedNote.new_debounced(Ecto.UUID.generate(),
          clamp: false,
          priority: EmbedNote.backfill_priority()
        )

      assert Ecto.Changeset.get_field(changeset, :priority) == EmbedNote.backfill_priority()
    end

    test "a backfill-priority job is still a valid Oban changeset" do
      changeset =
        EmbedNote.new_debounced(Ecto.UUID.generate(),
          clamp: false,
          priority: EmbedNote.backfill_priority()
        )

      assert changeset.valid?
    end
  end

  describe "end-to-end ordering" do
    test "a live edit outranks a bulk-import backlog in Oban's fetch order", %{} do
      user = insert(:user)
      vault = insert(:vault, user: user)

      # 5 never-embedded notes (a bulk import) enqueued FIRST...
      for i <- 1..5 do
        note = insert(:note, user: user, vault: vault, embed_hash: nil, path: "import#{i}.md")

        {:ok, _} =
          Oban.insert(EmbedNote.new_debounced(note.id, priority: EmbedNote.priority_for(note)))
      end

      # ...then one live edit of an already-embedded note, enqueued LAST.
      edited = insert(:note, user: user, vault: vault, embed_hash: "old", path: "live.md")

      {:ok, _} =
        Oban.insert(EmbedNote.new_debounced(edited.id, priority: EmbedNote.priority_for(edited)))

      # Oban fetches priority ASC, then scheduled_at/id. Despite being inserted
      # last, the live edit must sort first.
      first =
        Oban.Job
        |> where([j], j.worker == "Engram.Workers.EmbedNote")
        |> order_by([j], asc: j.priority, asc: j.scheduled_at, asc: j.id)
        |> limit(1)
        |> Repo.one(skip_tenant_check: true)

      assert first.args["note_id"] == edited.id
    end
  end
end
