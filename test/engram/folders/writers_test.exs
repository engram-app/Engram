defmodule Engram.Folders.WritersTest do
  # R9.4: every writer that stores a path also finds or creates the folder row
  # and points the note / attachment at it by id, while the stored paths stay
  # authoritative (the previous release is the rollback target and ignores the
  # new column).
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.{Attachments, Folders, Notes, Repo}
  alias Engram.FolderRows
  alias Engram.Folders.Rows

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp put_note(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "# T\n\nbody"}, actor: "api")

    note
  end

  defp put_att(user, vault, path) do
    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => path,
        "content_base64" => Base.encode64("bytes of " <> path)
      })

    att
  end

  defp ref(table, id), do: FolderRows.ref(table, id)
  defp tree(user), do: FolderRows.tree(user)

  defp stored_path(user, vault, id) do
    {:ok, n} = Notes.get_note_by_id(user, vault, id)
    n.path
  end

  describe "notes" do
    test "a REST/MCP upsert creates the chain and points the note at its leaf", %{
      user: u,
      vault: v
    } do
      note = put_note(u, v, "A/B/C/n.md")
      t = tree(u)

      assert Map.keys(t) |> Enum.sort() == ["A", "A/B", "A/B/C"]
      assert ref("notes", note.id) == t["A/B/C"].id
      refute t["A/B/C"].explicit
    end

    test "a root note has no folder row and a NULL ref", %{user: u, vault: v} do
      note = put_note(u, v, "Root.md")
      assert tree(u) == %{}
      assert ref("notes", note.id) == nil
    end

    test "a second note reuses the folder row", %{user: u, vault: v} do
      a = put_note(u, v, "Dir/a.md")
      b = put_note(u, v, "Dir/b.md")
      assert ref("notes", a.id) == ref("notes", b.id)
      assert map_size(tree(u)) == 1
    end

    test "a CRDT genesis create points the note at its folder", %{user: u, vault: v} do
      id = Notes.mint_id()
      {:ok, note} = Notes.genesis_crdt_note(u, v, id, "G/H/new.md")
      assert ref("notes", note.id) == tree(u)["G/H"].id
    end

    test "rename_note into a new folder creates the row and moves the ref", %{user: u, vault: v} do
      note = put_note(u, v, "Old/n.md")
      assert {:ok, _} = Notes.rename_note(u, v, "Old/n.md", "New/Deeper/n.md")

      t = tree(u)
      assert ref("notes", note.id) == t["New/Deeper"].id
      assert stored_path(u, v, note.id) == "New/Deeper/n.md"
    end

    test "a CRDT relocate and a resurrect point at the new folder", %{user: u, vault: v} do
      note = put_note(u, v, "R/n.md")

      # Relocate: the same id claimed at a new path.
      {:ok, moved} = Notes.genesis_crdt_note(u, v, note.id, "R2/n.md")
      assert ref("notes", moved.id) == tree(u)["R2"].id
    end
  end

  describe "folders" do
    test "creating a marker makes an explicit row that keeps the marker's UUID", %{
      user: u,
      vault: v
    } do
      {:ok, %{folders: [%{id: marker_id}]}} = Notes.create_folder_markers(u, v, ["Mk/Sub"])

      t = tree(u)
      assert t["Mk/Sub"].id == marker_id
      assert t["Mk/Sub"].explicit
      refute t["Mk"].explicit
    end

    test "a folder rename keeps the rows, rewrites the stored paths and leaves refs alone", %{
      user: u,
      vault: v
    } do
      n1 = put_note(u, v, "A/B/n1.md")
      n2 = put_note(u, v, "A/n2.md")
      att = put_att(u, v, "A/B/pic.png")
      before = tree(u)

      assert {:ok, %{notes: 2, attachments: 1}} = Folders.rename(u, v, "A", "Z")

      after_ = tree(u)
      # Same rows, new paths: identity survived.
      assert after_["Z"].id == before["A"].id
      assert after_["Z/B"].id == before["A/B"].id
      refute Map.has_key?(after_, "A")
      refute Map.has_key?(after_, "A/B")

      # Notes and the attachment still point at the same rows...
      assert ref("notes", n1.id) == after_["Z/B"].id
      assert ref("notes", n2.id) == after_["Z"].id
      assert ref("attachments", att.id) == after_["Z/B"].id
      # ...and the stored paths changed exactly as before (rollback safety).
      assert stored_path(u, v, n1.id) == "Z/B/n1.md"
      assert stored_path(u, v, n2.id) == "Z/n2.md"
      assert {:ok, %{id: id}} = Attachments.get_attachment(u, v, "Z/B/pic.png")
      assert id == att.id
      assert Attachments.get_attachment(u, v, "A/B/pic.png") == {:ok, nil}
    end

    test "a folder move under another parent re-parents the row", %{user: u, vault: v} do
      put_note(u, v, "Src/Inner/n.md")
      put_note(u, v, "Dst/keep.md")
      before = tree(u)

      assert {:ok, _} = Folders.rename(u, v, "Src", "Dst/Src")

      t = tree(u)
      assert t["Dst/Src"].id == before["Src"].id
      assert t["Dst/Src/Inner"].id == before["Src/Inner"].id
    end

    test "delete stamps the rows with the op id and restore brings them back", %{
      user: u,
      vault: v
    } do
      note = put_note(u, v, "Del/Sub/n.md")
      att = put_att(u, v, "Del/Sub/p.png")
      before = tree(u)
      op = Ecto.UUID.generate()

      assert {:ok, %{notes: 1, attachments: 1}} =
               Folders.delete(u, v, "Del", recursive: true, op_id: op)

      for path <- ["Del", "Del/Sub"] do
        row = FolderRows.row(before[path].id)
        assert row.deleted_at
        assert row.delete_op_id == op
      end

      assert tree(u) == %{}

      assert {:ok, %{notes: 1, attachments: 1}} = Folders.restore_op(u, v, op)

      assert tree(u) |> Map.new(fn {k, f} -> {k, f.id} end) ==
               Map.new(before, fn {k, f} -> {k, f.id} end)

      assert ref("notes", note.id) == before["Del/Sub"].id
      assert ref("attachments", att.id) == before["Del/Sub"].id
    end

    test "deleting a marker only clears the explicit flag", %{user: u, vault: v} do
      put_note(u, v, "Keep/n.md")
      {:ok, _} = Notes.create_folder_marker(u, v, "Keep")
      assert tree(u)["Keep"].explicit

      assert {:ok, :deleted} = Notes.delete_folder_marker(u, v, "Keep")
      assert %{explicit: false} = tree(u)["Keep"]
    end
  end

  describe "attachments" do
    test "an upload points at its folder; a root upload has no ref", %{user: u, vault: v} do
      a = put_att(u, v, "Pics/2026/a.png")
      r = put_att(u, v, "root.png")

      assert ref("attachments", a.id) == tree(u)["Pics/2026"].id
      assert ref("attachments", r.id) == nil
    end

    test "a re-upload to the same path keeps the ref", %{user: u, vault: v} do
      a = put_att(u, v, "Pics/a.png")
      first = ref("attachments", a.id)

      {:ok, again} =
        Attachments.upsert_attachment(u, v, %{
          "path" => "Pics/a.png",
          "content_base64" => Base.encode64("other bytes")
        })

      assert again.id == a.id
      assert ref("attachments", a.id) == first
    end

    test "move_attachment and batch_move repoint the ref", %{user: u, vault: v} do
      a = put_att(u, v, "One/a.png")
      b = put_att(u, v, "One/b.png")

      assert {:ok, _} = Attachments.move_attachment(u, v, "One/a.png", "Two/a.png")
      assert ref("attachments", a.id) == tree(u)["Two"].id

      assert {:ok, %{moved: 1}} = Attachments.batch_move(u, v, ["One/b.png"], "Three/Deep")
      assert ref("attachments", b.id) == tree(u)["Three/Deep"].id

      assert {:ok, _} = Attachments.move_attachment(u, v, "Two/a.png", "a.png")
      assert ref("attachments", a.id) == nil
    end
  end

  test "writers leave exactly one live row per folder path", %{user: u, vault: v} do
    for i <- 1..3, do: put_note(u, v, "Same/Dir/n#{i}.md")
    for i <- 1..3, do: put_att(u, v, "Same/Dir/p#{i}.png")

    {:ok, count} =
      Repo.with_tenant(u.id, fn ->
        {:ok, fk} = Engram.Crypto.dek_filter_key(u)
        hmac = Rows.path_hmac(fk, "Same/Dir")

        Repo.aggregate(
          from(f in Engram.Folders.Folder, where: f.full_path_hmac == ^hmac),
          :count
        )
      end)

    assert count == 1
  end
end
