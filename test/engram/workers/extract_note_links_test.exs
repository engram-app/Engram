defmodule Engram.Workers.ExtractNoteLinksTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.{Crypto, Links, Notes, Repo}
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, Note}
  alias Engram.Workers.ExtractNoteLinks

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  test "extracts edges from current note content", %{user: user, vault: vault} do
    {:ok, target} = Notes.upsert_note(user, vault, %{"path" => "Target.md", "content" => "# t"})

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "S.md", "content" => "see [[Target]]"})

    assert :ok = perform_job(ExtractNoteLinks, %{note_id: note.id})

    assert [%{target_text: "Target", target_note_id: tid, dangling: false}] =
             Links.links_for_note(user, note.id)

    assert tid == target.id
  end

  test "a note emptied to \"\" clears its stale edges (:no_chunks class)",
       %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "S.md", "content" => "see [[X]]"})
    assert :ok = perform_job(ExtractNoteLinks, %{note_id: note.id})
    assert [_] = Links.links_for_note(user, note.id)

    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "S.md", "content" => ""})
    assert :ok = perform_job(ExtractNoteLinks, %{note_id: note.id})
    assert [] == Links.links_for_note(user, note.id)
  end

  test "missing note discards", %{user: _user} do
    assert {:discard, _} = perform_job(ExtractNoteLinks, %{note_id: Ecto.UUID.generate()})
  end

  test "soft-deleted note discards", %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "D.md", "content" => "x [[Y]]"})
    :ok = Notes.delete_note(user, vault, "D.md")
    assert {:discard, _} = perform_job(ExtractNoteLinks, %{note_id: note.id})
  end

  test "new_debounced dedups per note over available/scheduled", %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "S.md", "content" => "a"})

    {:ok, _} = Oban.insert(ExtractNoteLinks.new_debounced(note.id))
    {:ok, _} = Oban.insert(ExtractNoteLinks.new_debounced(note.id))

    assert [job] = all_enqueued(worker: ExtractNoteLinks)
    assert job.args["note_id"] == note.id
    # Leading-edge: ~2s out, never immediate.
    assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt
  end

  describe "wiring" do
    test "REST upsert enqueues extraction on content change, not on no-op",
         %{user: user, vault: vault} do
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "W.md", "content" => "v1"})
      assert [%{args: %{"note_id" => id}}] = all_enqueued(worker: ExtractNoteLinks)
      assert id == note.id

      Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.ExtractNoteLinks"))

      # Idempotent re-push of identical content: no version/seq persisted → no job.
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "W.md", "content" => "v1"})
      assert [] == all_enqueued(worker: ExtractNoteLinks)
    end

    test "CRDT checkpoint content change enqueues extraction",
         %{user: user, vault: vault} do
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "C.md", "content" => "old"})
      Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.ExtractNoteLinks"))

      {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
      {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)
      {:ok, doc} = CrdtBridge.doc_from_state(raw_state)

      :ok =
        CrdtBridge.diff_into_text(
          Yex.Doc.get_text(doc, CrdtBridge.text_name()),
          "new [[Linked]]"
        )

      :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

      assert [%{args: %{"note_id" => id}}] = all_enqueued(worker: ExtractNoteLinks)
      assert id == note.id
    end

    test "REST moved leg (rename resurrect) enqueues extraction on content change, not on same content",
         %{user: user, vault: vault} do
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "M1.md", "content" => "before"})
      :ok = Notes.delete_note(user, vault, "M1.md")
      Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.ExtractNoteLinks"))

      # Id-keyed rename resurrect (upsert_pathless -> move_note) with DIFFERENT
      # content: hash changes, job enqueued.
      assert {:ok, moved} =
               Notes.upsert_note(user, vault, %{
                 "id" => note.id,
                 "path" => "M2.md",
                 "content" => "after"
               })

      assert [%{args: %{"note_id" => id}}] = all_enqueued(worker: ExtractNoteLinks)
      assert id == moved.id

      Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.ExtractNoteLinks"))
      :ok = Notes.delete_note(user, vault, "M2.md")
      Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.ExtractNoteLinks"))

      # Same rename resurrect shape, but SAME content as the tombstoned note:
      # merge produces an identical hash, no job.
      assert {:ok, _} =
               Notes.upsert_note(user, vault, %{
                 "id" => note.id,
                 "path" => "M3.md",
                 "content" => "after"
               })

      assert [] == all_enqueued(worker: ExtractNoteLinks)
    end

    test "batch upsert enqueues one extraction job per changed note", %{
      user: user,
      vault: vault
    } do
      notes = [
        %{"path" => "ba.md", "content" => "alpha", "mtime" => 1.0},
        %{"path" => "bb.md", "content" => "beta", "mtime" => 1.0}
      ]

      assert {:ok, %{results: results}} = Notes.batch_upsert_notes(user, vault, notes)
      ids = Enum.map(results, & &1.id)

      jobs = all_enqueued(worker: ExtractNoteLinks)
      assert Enum.sort(Enum.map(jobs, & &1.args["note_id"])) == Enum.sort(ids)
    end

    test "batch upsert skips the extraction job when content is unchanged", %{
      user: user,
      vault: vault
    } do
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "bc.md", "content" => "same"})
      Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.ExtractNoteLinks"))

      assert {:ok, %{results: [%{status: :ok}]}} =
               Notes.batch_upsert_notes(user, vault, [
                 %{"path" => "bc.md", "content" => "same", "mtime" => 2.0}
               ])

      assert [] == all_enqueued(worker: ExtractNoteLinks)
    end
  end
end
