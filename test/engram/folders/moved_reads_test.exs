defmodule Engram.Folders.MovedReadsTest do
  # O(1) folder rename plan, S5 readers (Engram#2523). The S5 writer (a later
  # release) renames ONE folder row (`notes_cascaded = false`) and leaves the
  # notes under it at their OLD stored path. This release must already read,
  # write next to, delete and restore such rows correctly, with no writer of
  # its own: it is the writer's rollback target and the code old nodes run in
  # a rolling deploy. The rows here are made in the writer's shape by
  # `FolderRows.move_uncascaded!/3`, never by this release's code.
  use Engram.DataCase, async: true

  alias Engram.{Crypto, FolderRows, Folders, Links, Notes, Repo}
  alias Engram.Folders.Rows
  alias Engram.Links.Parser
  alias Engram.MCP.Handlers

  setup do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    notes = for i <- 1..3, into: %{}, do: {i, put!(user, vault, "A/n#{i}.md", "note #{i}")}
    _ = put!(user, vault, "A/sub/deep.md", "deep")
    other = put!(user, vault, "Other/o.md", "other")

    # The S5 writer's shape: folder A renamed to B, one row, no note row.
    FolderRows.move_uncascaded!(user, folder_id(user, vault, "A"), "B")

    %{user: user, vault: vault, notes: notes, other: other}
  end

  defp put!(user, vault, path, content) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")

    note
  end

  defp folder_id(user, vault, path),
    do: Repo.with_tenant!(user.id, fn -> Rows.ids_by_path(user, vault.id, [path]) end)[path]

  defp row(user, id) do
    Repo.with_tenant!(user.id, fn ->
      Repo.one(
        from(n in Notes.Note,
          where: n.id == ^id,
          select: %{version: n.version, seq: n.seq, deleted_at: n.deleted_at}
        )
      )
    end)
  end

  defp feed_path(user, vault, id) do
    {:ok, %{changes: changes}} = Notes.list_changes_by_seq(user, vault, 0, limit: 500)
    Enum.find_value(changes, &(&1.id == id && &1.path))
  end

  describe "a save at a moved note's old path" do
    test "REST: a new note, and the moved note is untouched", %{user: u, vault: v, notes: ns} do
      moved = ns[1]
      before = row(u, moved.id)

      fresh = put!(u, v, "A/n1.md", "fresh")

      assert fresh.id != moved.id
      assert row(u, moved.id) == before

      assert {:ok, %{id: id, content: "note 1", path: "B/n1.md"}} =
               Notes.get_note(u, v, "B/n1.md")

      assert id == moved.id
      assert {:ok, %{content: "fresh"}} = Notes.get_note(u, v, "A/n1.md")
    end

    test "MCP write_note: a new note, the moved note keeps its content", %{user: u, vault: v} do
      assert {:ok, _, _} =
               Handlers.handle("write_note", u, v, %{"path" => "A/n2.md", "content" => "mcp"})

      assert {:ok, %{content: "note 2"}} = Notes.get_note(u, v, "B/n2.md")
      assert {:ok, %{content: "mcp"}} = Notes.get_note(u, v, "A/n2.md")
    end

    test "a rename onto it takes it", %{user: u, vault: v} do
      assert {:ok, _} = Notes.rename_note(u, v, "Other/o.md", "A/n3.md")
      assert {:ok, %{content: "other"}} = Notes.get_note(u, v, "A/n3.md")
      assert {:ok, %{content: "note 3"}} = Notes.get_note(u, v, "B/n3.md")
    end

    test "a CRDT relocate onto it takes it", %{user: u, vault: v, other: other} do
      assert {:ok, %{id: id}} = Notes.genesis_crdt_note(u, v, other.id, "A/n3.md")
      assert id == other.id
      assert {:ok, %{id: ^id}} = Notes.get_note(u, v, "A/n3.md")
      assert {:ok, %{content: "note 3"}} = Notes.get_note(u, v, "B/n3.md")
    end
  end

  describe "reads" do
    test "by path, by id and the CRDT channel's path", %{user: u, vault: v, notes: ns} do
      assert {:error, :not_found} = Notes.get_note(u, v, "A/n1.md")
      assert {:ok, %{path: "B/sub/deep.md"}} = Notes.get_note(u, v, "B/sub/deep.md")
      assert {:ok, %{path: "B/n2.md"}} = Notes.get_note_by_id(u, v, ns[2].id)
      assert Notes.live_note_path(u, v, ns[2].id) == {:ok, "B/n2.md"}
      id2 = ns[2].id
      assert {:ok, %{^id2 => %{path: "B/n2.md"}}} = Notes.get_note_meta_by_ids(u, v, [id2])
    end

    test "a link to the new path resolves to the moved note", %{user: u, vault: v, notes: ns} do
      src = put!(u, v, "idx.md", "[[B/n1]]")
      :ok = Links.replace_links(u, v, src.id, Parser.extract("[[B/n1]]"))
      assert [%{target_note_id: id}] = Links.links_for_note(u, src.id)
      assert id == ns[1].id
    end
  end

  describe "a re-create of a moved note at its new path" do
    test "is not a relocate: no write", %{user: u, vault: v, notes: ns} do
      before = row(u, ns[1].id)
      assert {:ok, %{id: id}} = Notes.genesis_crdt_note(u, v, ns[1].id, "B/n1.md")
      assert id == ns[1].id
      assert row(u, ns[1].id) == before
    end
  end

  describe "deletes leave the tombstone where the note was shown" do
    test "one note", %{user: u, vault: v, notes: ns} do
      assert :deleted = Notes.delete_note_reporting(u, v, "B/n1.md")
      assert feed_path(u, v, ns[1].id) == "B/n1.md"
    end

    test "a batch", %{user: u, vault: v, notes: ns} do
      assert {:ok, %{deleted: 2}} = Notes.batch_delete_notes(u, v, [ns[1].id, ns[2].id])
      assert feed_path(u, v, ns[1].id) == "B/n1.md"
      assert feed_path(u, v, ns[2].id) == "B/n2.md"
    end

    test "the moved folder, recursively", %{user: u, vault: v, notes: ns} do
      assert {:ok, %{notes: 4}} = Folders.delete(u, v, "B", recursive: true)
      assert {:error, :not_found} = Notes.get_note(u, v, "B/n1.md")
      assert {:error, :not_found} = Notes.get_note(u, v, "A/n1.md")
      assert feed_path(u, v, ns[3].id) == "B/n3.md"
      assert {:ok, _} = Notes.get_note(u, v, "Other/o.md")
    end
  end

  test "a cascading rename of the moved folder lands every note", %{user: u, vault: v} do
    assert {:ok, %{notes: 4}} = Folders.rename(u, v, "B", "C")
    assert {:ok, %{path: "C/n1.md"}} = Notes.get_note(u, v, "C/n1.md")
    assert {:ok, %{path: "C/sub/deep.md"}} = Notes.get_note(u, v, "C/sub/deep.md")
    assert {:error, :not_found} = Notes.get_note(u, v, "B/n1.md")
    assert {:error, :not_found} = Notes.get_note(u, v, "A/n1.md")
  end
end
