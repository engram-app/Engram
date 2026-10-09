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
  alias Engram.Workers.{EmbedNote, ExtractNoteLinks, FinalizeRevision, NoteCommitted}

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

  # The checkpoint inserts ONE dispatcher job after it commits (not under the
  # vault seq lock, #1710); the dispatcher enqueues the three.
  defp run_dispatchers do
    for job <- all_enqueued(worker: NoteCommitted), do: :ok = perform_job(NoteCommitted, job.args)
  end

  defp checkpoint_text(u, v, note_id, text) do
    {:ok, raw} = Repo.with_tenant(u.id, fn -> Repo.get!(Note, note_id) end)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, u)
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), text)
    :ok = CrdtCheckpoint.checkpoint(u.id, v.id, note_id, doc)
  end

  test "a content-changing checkpoint runs it", %{user: u, vault: v} do
    {:ok, note} =
      Notes.upsert_note(u, v, %{"path" => "c.md", "content" => "before"}, actor: "api")

    drop_jobs()
    checkpoint_text(u, v, note.id, "after")

    assert [_] = all_enqueued(worker: NoteCommitted, args: %{note_id: note.id})
    refute_enqueued(worker: EmbedNote, args: %{note_id: note.id})

    run_dispatchers()
    assert_all_enqueued(note.id)
  end

  test "two checkpoints still leave one embed and one link job", %{user: u, vault: v} do
    {:ok, note} =
      Notes.upsert_note(u, v, %{"path" => "d.md", "content" => "before"}, actor: "api")

    drop_jobs()
    checkpoint_text(u, v, note.id, "after one")
    checkpoint_text(u, v, note.id, "after two")
    assert [_, _] = all_enqueued(worker: NoteCommitted, args: %{note_id: note.id})

    run_dispatchers()

    for worker <- [EmbedNote, ExtractNoteLinks, FinalizeRevision] do
      assert [_] = all_enqueued(worker: worker, args: %{note_id: note.id}), inspect(worker)
    end
  end

  # The dispatcher is the only durable carrier of the three jobs, so a failed
  # insert must fail the job (Oban retries it; uniqueness keeps that safe).
  test "the dispatcher fails when a downstream insert fails, and its retry dedupes" do
    note_id = Ecto.UUID.generate()
    args = %{note_id: note_id, user_id: Ecto.UUID.generate(), finalize: false}

    # An out-of-range priority makes the EmbedNote insert invalid.
    assert {:error, _} = perform_job(NoteCommitted, Map.put(args, :embed_priority, 42))
    assert {:error, _} = perform_job(NoteCommitted, Map.put(args, :embed_priority, 42))
    assert [_] = all_enqueued(worker: ExtractNoteLinks, args: %{note_id: note_id})

    assert :ok = perform_job(NoteCommitted, Map.put(args, :embed_priority, 0))
    assert [_] = all_enqueued(worker: EmbedNote, args: %{note_id: note_id})
    assert [_] = all_enqueued(worker: ExtractNoteLinks, args: %{note_id: note_id})
  end

  test "the first checkpoint of a CRDT-created note enqueues no finalize",
       %{user: u, vault: v} do
    id = UUIDv7.generate()
    {:ok, _} = Notes.genesis_crdt_note(u, v, id, "g.md")
    doc = Yex.Doc.new()
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "first")

    :ok = CrdtCheckpoint.checkpoint(u.id, v.id, id, doc)
    run_dispatchers()

    assert_enqueued(worker: EmbedNote, args: %{note_id: id})
    refute_enqueued(worker: FinalizeRevision, args: %{note_id: id})
  end
end
