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

  test "enqueue_jobs enqueues embed, links and finalize" do
    note_id = Ecto.UUID.generate()

    :ok =
      ContentCommit.enqueue_jobs(note_id, Ecto.UUID.generate(),
        embed_priority: 0,
        finalize?: true
      )

    assert_all_enqueued(note_id)
  end

  # The create enqueues embed and links too, so drop them: the update alone
  # must be what the assertions see.
  defp drop_jobs, do: Repo.delete_all(Oban.Job)

  test "an upsert that changes content runs it", %{user: u, vault: v} do
    {:ok, note} = Notes.upsert_note(u, v, %{"path" => "u.md", "content" => "one"}, actor: "api")
    drop_jobs()
    {:ok, _} = Notes.upsert_note(u, v, %{"path" => "u.md", "content" => "two"}, actor: "api")
    assert_all_enqueued(note.id)
  end

  test "a create enqueues no finalize", %{user: u, vault: v} do
    {:ok, note} = Notes.upsert_note(u, v, %{"path" => "new.md", "content" => "one"}, actor: "api")
    refute_enqueued(worker: FinalizeRevision, args: %{note_id: note.id})
  end

  test "an update by a user without history enqueues no finalize", %{user: u, vault: v} do
    insert(:user_limit_override, user: u, key: "history_enabled", value: %{"v" => false})
    {:ok, note} = Notes.upsert_note(u, v, %{"path" => "nh.md", "content" => "one"}, actor: "api")
    {:ok, _} = Notes.upsert_note(u, v, %{"path" => "nh.md", "content" => "two"}, actor: "api")
    refute_enqueued(worker: FinalizeRevision, args: %{note_id: note.id})
  end

  test "a content-changing checkpoint runs it", %{user: u, vault: v} do
    {:ok, note} =
      Notes.upsert_note(u, v, %{"path" => "c.md", "content" => "before"}, actor: "api")

    drop_jobs()
    {:ok, raw} = Repo.with_tenant(u.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, u)
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "after")

    :ok = CrdtCheckpoint.checkpoint(u.id, v.id, note.id, doc)

    assert_enqueued(worker: FinalizeRevision, args: %{note_id: note.id})
  end

  test "the first checkpoint of a CRDT-created note enqueues no finalize",
       %{user: u, vault: v} do
    id = UUIDv7.generate()
    {:ok, _} = Notes.genesis_crdt_note(u, v, id, "g.md")
    doc = Yex.Doc.new()
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "first")

    :ok = CrdtCheckpoint.checkpoint(u.id, v.id, id, doc)

    assert_enqueued(worker: EmbedNote, args: %{note_id: id})
    refute_enqueued(worker: FinalizeRevision, args: %{note_id: id})
  end
end
