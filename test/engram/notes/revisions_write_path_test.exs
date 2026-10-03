defmodule Engram.Notes.RevisionsWritePathTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, CrdtPersistence, Note, Revision, Revisions}
  alias Engram.Workers.FinalizeRevision

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "WritePath", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  def revisions(user, note_id) do
    {:ok, revs} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(from(r in Revision, where: r.note_id == ^note_id))
      end)

    revs
  end

  def open(revs), do: Enum.find(revs, &is_nil(&1.closed_at))
  def text_of(user, rev), do: elem(Revisions.decrypt_pending(rev, user), 1)

  def checkpoint_text(user, vault, note_id, text) do
    {:ok, raw} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note_id) end)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, user)
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), text)
    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note_id, doc)
  end

  describe "checkpoint" do
    test "a content change records a baseline and opens a sync version", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "cp.md", "content" => "before"})

      checkpoint_text(u, v, note.id, "after")

      revs = revisions(u, note.id)
      assert text_of(u, Enum.find(revs, &(&1.origin == "baseline"))) == "before"
      assert %Revision{actor: "sync"} = open(revs)
    end

    test "a compaction (unchanged text) records nothing new", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "cp2.md", "content" => "before"})
      checkpoint_text(u, v, note.id, "after")
      count = length(revisions(u, note.id))

      checkpoint_text(u, v, note.id, "after")

      assert length(revisions(u, note.id)) == count
    end
  end

  describe "upsert_note" do
    test "an update records with the caller's actor", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "up.md", "content" => "v1"})

      {:ok, _} = Notes.upsert_note(u, v, %{"path" => "up.md", "content" => "v2"}, actor: "mcp")

      revs = revisions(u, note.id)
      assert text_of(u, Enum.find(revs, &(&1.origin == "baseline"))) == "v1"
      assert %Revision{actor: "mcp"} = open(revs)
    end

    test "no actor means \"api\"", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "api.md", "content" => "v1"})
      {:ok, _} = Notes.upsert_note(u, v, %{"path" => "api.md", "content" => "v2"})
      assert %Revision{actor: "api"} = open(revisions(u, note.id))
    end

    test "you typing, then an MCP write: your version holds exactly your text",
         %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "split.md", "content" => "start"})
      checkpoint_text(u, v, note.id, "you typed this")
      yours = open(revisions(u, note.id))

      {:ok, _} =
        Notes.upsert_note(u, v, %{"path" => "split.md", "content" => "ai rewrote"}, actor: "mcp")

      revs = revisions(u, note.id)
      assert text_of(u, Enum.find(revs, &(&1.id == yours.id))) == "you typed this"
      assert %Revision{actor: "mcp"} = open(revs)
    end

    test "an idempotent re-push records nothing", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "same.md", "content" => "v1"})
      {:ok, _} = Notes.upsert_note(u, v, %{"path" => "same.md", "content" => "v2"}, actor: "mcp")
      count = length(revisions(u, note.id))

      {:ok, _} = Notes.upsert_note(u, v, %{"path" => "same.md", "content" => "v2"}, actor: "mcp")

      assert length(revisions(u, note.id)) == count
    end

    test "batch updates record as import", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "bulk.md", "content" => "v1"})
      Notes.batch_upsert_notes(u, v, [%{"path" => "bulk.md", "content" => "v2"}])
      assert %Revision{actor: "import", origin: "import"} = open(revisions(u, note.id))
    end

    test "a content-changing id-keyed move records with the caller's actor",
         %{user: u, vault: v} do
      id = UUIDv7.generate()
      {:ok, _} = Notes.upsert_note(u, v, %{"id" => id, "path" => "A.md", "content" => "v1"})
      :ok = Notes.delete_note(u, v, "A.md")

      {:ok, moved} =
        Notes.upsert_note(u, v, %{"id" => id, "path" => "B.md", "content" => "v2"}, actor: "mcp")

      assert moved.path == "B.md"
      assert %Revision{actor: "mcp"} = open(revisions(u, id))
    end

    test "a pure id-keyed rename records nothing", %{user: u, vault: v} do
      id = UUIDv7.generate()
      {:ok, _} = Notes.upsert_note(u, v, %{"id" => id, "path" => "A.md", "content" => "v1"})
      :ok = Notes.delete_note(u, v, "A.md")
      count = length(revisions(u, id))

      {:ok, _} =
        Notes.upsert_note(u, v, %{"id" => id, "path" => "B.md", "content" => "v1"}, actor: "mcp")

      assert length(revisions(u, id)) == count
    end
  end

  # An uncheckpointed CRDT edit: the tail holds `text`, the note row does not.
  def tail_edit(user, vault, note_id, text) do
    {:ok, raw} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note_id) end)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, user)
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    {:ok, sv} = Yex.encode_state_vector(doc)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), text)
    {:ok, update} = Yex.encode_state_as_update(doc, sv)
    room = %{user_id: user.id, vault_id: vault.id, note_id: note_id, user: user}
    _ = CrdtPersistence.update_v1(room, update, nil, doc)
    :ok
  end

  def drop_finalize_jobs,
    do: Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.FinalizeRevision"))

  describe "CRDT relocate" do
    test "a content-changing relocate enqueues its finalize", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "r1.md", "content" => "before"})
      :ok = tail_edit(u, v, note.id, "after")
      drop_finalize_jobs()

      {:ok, moved} = Notes.genesis_crdt_note(u, v, note.id, "r2.md")

      assert moved.path == "r2.md"
      revs = revisions(u, note.id)
      assert text_of(u, Enum.find(revs, &(&1.origin == "baseline"))) == "before"
      assert_enqueued(worker: FinalizeRevision, args: %{note_id: note.id})
    end

    test "a pure relocate enqueues none", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "p1.md", "content" => "same"})
      drop_finalize_jobs()

      {:ok, _} = Notes.genesis_crdt_note(u, v, note.id, "p2.md")

      refute_enqueued(worker: FinalizeRevision, args: %{note_id: note.id})
    end

    test "a content-changing resurrect enqueues its finalize", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "z1.md", "content" => "before"})
      :ok = tail_edit(u, v, note.id, "after")
      :ok = Notes.delete_note(u, v, "z1.md")
      drop_finalize_jobs()

      {:ok, _} = Notes.genesis_crdt_note(u, v, note.id, "z2.md")

      assert_enqueued(worker: FinalizeRevision, args: %{note_id: note.id})
    end
  end

  describe "finalize jobs" do
    test "a batch update enqueues one while recording is on", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "on.md", "content" => "v1"})
      Notes.batch_upsert_notes(u, v, [%{"path" => "on.md", "content" => "v2"}])
      assert_enqueued(worker: FinalizeRevision, args: %{note_id: note.id})
    end
  end

  describe "recording off" do
    setup do
      previous = Application.get_env(:engram, :history_recording)
      Application.put_env(:engram, :history_recording, false)
      on_exit(fn -> Application.put_env(:engram, :history_recording, previous) end)
    end

    test "an upsert enqueues no finalize job", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "off.md", "content" => "v1"})
      {:ok, _} = Notes.upsert_note(u, v, %{"path" => "off.md", "content" => "v2"})
      refute_enqueued(worker: FinalizeRevision, args: %{note_id: note.id})
    end

    test "a batch write enqueues no finalize job", %{user: u, vault: v} do
      Notes.batch_upsert_notes(u, v, [%{"path" => "boff.md", "content" => "v1"}])
      Notes.batch_upsert_notes(u, v, [%{"path" => "boff.md", "content" => "v2"}])
      refute_enqueued(worker: FinalizeRevision)
    end
  end
end
