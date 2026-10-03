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
end
