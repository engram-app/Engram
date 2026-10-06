defmodule Engram.Notes.ContentCommitTest do
  @moduledoc """
  Every content write must enqueue the same post-commit work. Before this
  module, the checkpoint and upsert_note each carried their own copy of that
  block, and a feature added to one could miss the other. That is exactly how
  #1710 would have shipped if it had hooked only the checkpoint: no history
  for any MCP edit.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{ContentCommit, CrdtBridge, CrdtCheckpoint, Note}
  alias Engram.Workers.{EmbedNote, ExtractNoteLinks, FinalizeRevision}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "Commit", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp assert_all_enqueued(note_id) do
    for worker <- [EmbedNote, ExtractNoteLinks, FinalizeRevision] do
      assert_enqueued(worker: worker, args: %{note_id: note_id})
    end
  end

  test "after_commit enqueues embed, links and finalize" do
    note_id = Ecto.UUID.generate()
    :ok = ContentCommit.after_commit(note_id, Ecto.UUID.generate(), embed_priority: 0)
    assert_all_enqueued(note_id)
  end

  test "an upsert that changes content runs it", %{user: u, vault: v} do
    {:ok, note} = Notes.upsert_note(u, v, %{"path" => "u.md", "content" => "one"})
    {:ok, _} = Notes.upsert_note(u, v, %{"path" => "u.md", "content" => "two"})
    assert_all_enqueued(note.id)
  end

  test "a content-changing checkpoint runs it", %{user: u, vault: v} do
    {:ok, note} = Notes.upsert_note(u, v, %{"path" => "c.md", "content" => "before"})
    {:ok, raw} = Repo.with_tenant(u.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, u)
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "after")

    :ok = CrdtCheckpoint.checkpoint(u.id, v.id, note.id, doc)

    assert_enqueued(worker: FinalizeRevision, args: %{note_id: note.id})
  end
end
