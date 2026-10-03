defmodule Engram.Notes.RevisionsWritePathTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, Note, Revision, Revisions}

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
end
