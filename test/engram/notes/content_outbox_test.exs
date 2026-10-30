defmodule Engram.Notes.ContentOutboxTest do
  @moduledoc """
  R6 outbox: every content write inserts its `NoteCommitted` job INSIDE its
  own transaction, so the job commits or rolls back with the write. Before,
  the checkpoint and the genesis body inserted it after the commit
  (`Repo.after_commit`), and a crash, a pool timeout or a raise in the
  post-commit work in between lost it; only the 5-minute reconcile sweep
  found the note again. With the sweep every 3 h that gap would be hours.

  `Repo.transaction_after_commit/1` is the seam: it owns the after-commit
  queue, so a job still deferred to "after the commit" is not in the table
  while the block runs, and one written in the write's transaction is.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, Note}
  alias Engram.Workers.{EmbedNote, NoteCommitted}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "Outbox", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp committed(note_id), do: all_enqueued(worker: NoteCommitted, args: %{note_id: note_id})

  defp doc_with(text) do
    {:ok, doc} = CrdtBridge.doc_from_state(nil)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), text)
    doc
  end

  defp checkpoint_text(u, v, note_id, text) do
    {:ok, raw} = Repo.with_tenant(u.id, fn -> Repo.get!(Note, note_id) end)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, u)
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), text)
    CrdtCheckpoint.checkpoint(u.id, v.id, note_id, doc)
  end

  defp put_hook(fun) do
    prev = Application.get_env(:engram, :checkpoint_interleave_hook)
    Application.put_env(:engram, :checkpoint_interleave_hook, fun)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:engram, :checkpoint_interleave_hook, prev),
        else: Application.delete_env(:engram, :checkpoint_interleave_hook)
    end)
  end

  describe "CRDT checkpoint" do
    setup %{user: u, vault: v} do
      {:ok, note} =
        Notes.upsert_note(u, v, %{"path" => "c.md", "content" => "before"}, actor: "api")

      Repo.delete_all(Oban.Job)
      %{note: note}
    end

    test "the job is in the table before the write's transaction ends",
         %{user: u, vault: v, note: note} do
      {:ok, seen} =
        Repo.transaction_after_commit(fn ->
          :ok = checkpoint_text(u, v, note.id, "after")
          committed(note.id)
        end)

      assert [_] = seen
    end

    # The post-commit work (name index, announce) ran first in the deferred
    # fun, so a raise there lost the job with the write already durable.
    test "a raise in the post-commit work still leaves the job", %{user: u, vault: v, note: note} do
      put_hook(fn
        :post_commit -> raise "post-commit boom"
        _ -> :ok
      end)

      ExUnit.CaptureLog.capture_log(fn -> :ok = checkpoint_text(u, v, note.id, "after") end)
      assert [_] = committed(note.id)
    end

    test "a write that rolls back leaves no job", %{user: u, vault: v, note: note} do
      {:error, :abort} =
        Repo.transaction_after_commit(fn ->
          :ok = checkpoint_text(u, v, note.id, "after")
          Repo.rollback(:abort)
        end)

      assert committed(note.id) == []
    end

    test "a checkpoint that changes no content queues nothing", %{user: u, vault: v, note: note} do
      :ok = checkpoint_text(u, v, note.id, "before")
      assert committed(note.id) == []
    end
  end

  describe "genesis body" do
    test "the job is in the table before the create's transaction ends", %{user: u, vault: v} do
      id = Ecto.UUID.generate()

      {:ok, seen} =
        Repo.transaction_after_commit(fn ->
          {:ok, _} = Notes.genesis_crdt_note(u, v, id, "g.md", body: doc_with("genesis body"))
          committed(id)
        end)

      assert [_] = seen
    end

    test "a bare genesis queues nothing", %{user: u, vault: v} do
      id = Ecto.UUID.generate()
      {:ok, _} = Notes.genesis_crdt_note(u, v, id, "bare.md")
      assert committed(id) == []
    end
  end

  describe "upsert_note" do
    # Before: three unique inserts (embed, links, finalize) after
    # `with_tenant` returned. Now one plain NoteCommitted in the write's
    # transaction; the dispatcher keeps each downstream job's uniqueness.
    test "a content write queues one NoteCommitted, written in the note's own transaction",
         %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "u.md", "content" => "one"}, actor: "api")

      assert [job] = committed(note.id)
      refute_enqueued(worker: EmbedNote, args: %{note_id: note.id})
      assert same_xmin?(u, note.id, job.id)
    end

    test "a write that rolls back leaves no job", %{user: u, vault: v} do
      {:error, :abort} =
        Repo.transaction_after_commit(fn ->
          {:ok, _} =
            Notes.upsert_note(u, v, %{"path" => "r.md", "content" => "one"}, actor: "api")

          Repo.rollback(:abort)
        end)

      assert all_enqueued(worker: NoteCommitted) == []
    end

    test "an unchanged rewrite queues nothing", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "s.md", "content" => "one"}, actor: "api")
      Repo.delete_all(Oban.Job)
      {:ok, _} = Notes.upsert_note(u, v, %{"path" => "s.md", "content" => "one"}, actor: "api")
      assert committed(note.id) == []
    end

    # #2294: an MCP write keeps its 2 s agent settle through the dispatcher.
    test "an MCP write carries the agent settle to its embed", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "m.md", "content" => "one"}, actor: "mcp")
      assert [job] = committed(note.id)
      assert job.args["embed_settle"] == "agent"
      assert job.priority == 0

      :ok = perform_job(NoteCommitted, job.args)
      [embed] = all_enqueued(worker: EmbedNote, args: %{note_id: note.id})

      assert DateTime.diff(embed.scheduled_at, DateTime.utc_now()) <=
               EmbedNote.agent_settle_seconds()
    end
  end

  # Rows written by one (sub)transaction share its xid. In the sandbox every
  # `Repo.transaction` is a savepoint with its own subxid, so a job inserted
  # after `with_tenant` returned carries a different xmin from the note.
  defp same_xmin?(user, note_id, job_id) do
    {:ok, {:ok, %{rows: [[a, b]]}}} =
      Repo.with_tenant(user.id, fn ->
        Repo.query(
          "SELECT (SELECT xmin::text FROM notes WHERE id = $1), (SELECT xmin::text FROM oban_jobs WHERE id = $2)",
          [Ecto.UUID.dump!(note_id), job_id]
        )
      end)

    a == b
  end
end
