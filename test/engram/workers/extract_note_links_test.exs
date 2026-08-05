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
  end
end
