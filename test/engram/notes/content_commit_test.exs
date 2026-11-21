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
  alias Engram.Notes.{ContentCommit, CrdtBridge, CrdtCheckpoint}
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
    run_dispatchers()
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

  # Every content write inserts ONE dispatcher job in its transaction (R6);
  # the dispatcher enqueues the three.
  defp run_dispatchers, do: Engram.Test.NoteCommittedDispatch.run()

  defp checkpoint_text(u, v, note_id, text) do
    {:ok, raw} = Repo.with_tenant(u.id, fn -> Engram.Fixtures.raw_note!(note_id) end)
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

  # {state, ms until it runs} of the note's one link-extraction job.
  defp link_job(note_id) do
    [job] = all_enqueued(worker: ExtractNoteLinks, args: %{note_id: note_id})
    {job.state, DateTime.diff(job.scheduled_at, DateTime.utc_now(), :millisecond)}
  end

  defp put(u, v, path, text, opts),
    do: Notes.upsert_note(u, v, %{"path" => path, "content" => text}, opts)

  # Agents and API callers write whole notes, so their links are extracted at
  # once; typing (CRDT checkpoints) and plugin pushes keep the 2 s delay that
  # folds a burst of edits into one run.
  test "an MCP or API write extracts links at once; a checkpoint or push waits",
       %{user: u, vault: v} do
    {:ok, typed} = put(u, v, "c.md", "before", actor: "api")
    drop_jobs()
    checkpoint_text(u, v, typed.id, "after")

    {:ok, mcp} = put(u, v, "m.md", "[[x]]", actor: "mcp")
    {:ok, api} = put(u, v, "a.md", "[[x]]", actor: "api:key", require_base: true)
    {:ok, push} = put(u, v, "p.md", "[[x]]", actor: "api:key")
    run_dispatchers()

    for note <- [mcp, api] do
      assert {"available", ms} = link_job(note.id)
      assert ms <= 0
    end

    for note <- [typed, push] do
      assert {"scheduled", ms} = link_job(note.id)
      assert ms > 1_000
    end
  end

  test "two back-to-back MCP edits leave one link job, which reads the final text",
       %{user: u, vault: v} do
    {:ok, _} = put(u, v, "First.md", "f", actor: "api")
    {:ok, _} = put(u, v, "Second.md", "s", actor: "api")
    {:ok, note} = put(u, v, "e.md", "[[First]]", actor: "mcp")
    {:ok, _} = put(u, v, "e.md", "[[Second]]", actor: "mcp")
    run_dispatchers()

    assert [job] = all_enqueued(worker: ExtractNoteLinks, args: %{note_id: note.id})
    assert :ok = perform_job(ExtractNoteLinks, job.args)

    assert [%{target_text: "Second", target_path: "Second.md"}] =
             Engram.Links.links_for_note(u, note.id)
  end

  # The dispatcher is the only durable carrier of the three jobs, so a failed
  # insert must fail the job (Oban retries it; uniqueness keeps that safe).
  # Every checkpoint passes through :events now; without a priority an
  # interactive edit's jobs queue behind a whole first-sync flood.
  test "the dispatcher runs at the embed priority" do
    for p <- [0, 3] do
      job =
        NoteCommitted.job(Ecto.UUID.generate(), Ecto.UUID.generate(),
          embed_priority: p,
          finalize?: false
        )

      assert Ecto.Changeset.get_field(job, :priority) == p
    end
  end

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

  # The checkpoint decides "did the note have text before" for its finalize
  # flag. It used to decrypt the whole old body for that, on every content
  # change, even with history recording off (prod). An unreadable body proves
  # the decision no longer reads it where it does not need to.
  describe "the checkpoint's finalize decision" do
    defp finalize_flags(note_id),
      do:
        for(
          j <- all_enqueued(worker: NoteCommitted, args: %{note_id: note_id}),
          do: j.args["finalize"]
        )

    defp put_body!(u, note_id, values),
      do:
        {:ok, _} =
          Repo.with_tenant(u.id, fn -> Engram.Fixtures.write_note_body!(note_id, values) end)

    # The stored body, sealed under the wrong AAD: any decrypt of it fails.
    defp unreadable_body!(u, note_id) do
      {:ok, dek} = Crypto.get_dek(u)
      {ct, nonce} = Engram.Crypto.Envelope.encrypt("junk", dek, "wrong-aad")
      put_body!(u, note_id, content_ciphertext: ct, content_nonce: nonce)
    end

    defp written(u, v, path, text) do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => path, "content" => text}, actor: "api")
      drop_jobs()
      note
    end

    test "a note that had text finalizes", %{user: u, vault: v} do
      note = written(u, v, "f1.md", "before")
      checkpoint_text(u, v, note.id, "after")
      assert finalize_flags(note.id) == [true]
    end

    test "an empty note does not", %{user: u, vault: v} do
      note = written(u, v, "f2.md", "")
      checkpoint_text(u, v, note.id, "after")
      assert finalize_flags(note.id) == [false]
    end

    test "a row with no hash does not", %{user: u, vault: v} do
      note = written(u, v, "f3.md", "before")
      put_body!(u, note.id, content_hash: nil)
      checkpoint_text(u, v, note.id, "after")
      assert finalize_flags(note.id) == [false]
    end

    test "with recording off the old body is never read", %{user: u, vault: v} do
      previous = Application.get_env(:engram, :history_recording)
      Application.put_env(:engram, :history_recording, false)
      on_exit(fn -> Application.put_env(:engram, :history_recording, previous) end)

      note = written(u, v, "f4.md", "before")
      unreadable_body!(u, note.id)
      checkpoint_text(u, v, note.id, "after")
      assert finalize_flags(note.id) == [false]
    end

    # Recording on and a non-empty hash: the old text decides, and an
    # unreadable one skips the checkpoint (as before) under a named warning.
    test "an unreadable old body with recording on is skipped and named", %{user: u, vault: v} do
      note = written(u, v, "f6.md", "before")
      unreadable_body!(u, note.id)
      {:ok, raw} = Repo.with_tenant(u.id, fn -> Engram.Fixtures.raw_note!(note.id) end)
      {:ok, state} = Crypto.decrypt_crdt_state(raw, u)
      {:ok, doc} = CrdtBridge.doc_from_state(state)
      :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "after")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :skipped = CrdtCheckpoint.checkpoint(u.id, v.id, note.id, doc)
        end)

      assert log =~ "crdt checkpoint old body unreadable"
      assert finalize_flags(note.id) == []
    end

    test "the hash of empty text decides without reading the body", %{user: u, vault: v} do
      note = written(u, v, "f5.md", "")
      unreadable_body!(u, note.id)
      checkpoint_text(u, v, note.id, "after")
      assert finalize_flags(note.id) == [false]
    end
  end
end
