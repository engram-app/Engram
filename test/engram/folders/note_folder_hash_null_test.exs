defmodule Engram.Folders.NoteFolderHashNullTest do
  # R9 write-stop prep: a later release stops writing `notes.folder_hmac` on
  # notes (a note's folder is its `folder_ref_id`; a path change writes NULL).
  # Every reader and trigger of this release must already handle a note with
  # no hash. Each test makes one, through the same function that later
  # release's writes would hit, and drives one reader.
  use Engram.DataCase, async: false

  alias Engram.Bookkeeping.Canary
  alias Engram.DataMigrations.FolderTable
  alias Engram.FolderRows
  alias Engram.Folders
  alias Engram.Notes
  alias Engram.Repo

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp dump(id), do: Ecto.UUID.dump!(id)
  defp ref(note), do: FolderRows.ref("notes", note.id)
  defp row_at(user, folder), do: FolderRows.tree(user)[folder].id

  defp note!(u, v, path) do
    {:ok, n} =
      Notes.upsert_note(u, v, %{"path" => path, "content" => "# T\n\nbody"}, actor: "api")

    n
  end

  # The later release's write: the hash cleared, nothing else named.
  defp clear_hash!(note),
    do: Repo.query!("UPDATE notes SET folder_hmac = NULL WHERE id = $1", [dump(note.id)])

  defp hash_of(note) do
    %{rows: [[h]]} = Repo.query!("SELECT folder_hmac FROM notes WHERE id = $1", [dump(note.id)])
    h
  end

  describe "schema" do
    test "a note may carry no folder hash; a marker may not", %{user: u, vault: v} do
      n = note!(u, v, "A/n.md")
      clear_hash!(n)
      assert hash_of(n) == nil

      {:ok, marker} = Notes.create_folder_marker(u, v, "M")

      assert_raise Postgrex.Error, ~r/notes_kind_shape_v4_check/, fn ->
        Repo.query!("UPDATE notes SET folder_hmac = NULL WHERE id = $1", [dump(marker.id)])
      end
    end

    test "clearing a note's hash keeps its folder reference", %{user: u, vault: v} do
      n = note!(u, v, "A/n.md")
      a = ref(n)
      assert a

      clear_hash!(n)
      assert ref(n) == a
    end
  end

  describe "restore" do
    test "a raw restore of a note with no hash keeps its live reference", %{user: u, vault: v} do
      n = note!(u, v, "A/n.md")
      a = ref(n)
      clear_hash!(n)

      Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [dump(n.id)])
      Repo.query!("UPDATE notes SET deleted_at = NULL WHERE id = $1", [dump(n.id)])

      assert ref(n) == a
    end

    test "a raw restore of a note with no hash and a dead reference is healed",
         %{user: u, vault: v} do
      n = note!(u, v, "A/n.md")
      a = ref(n)
      clear_hash!(n)
      Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [dump(n.id)])
      Repo.query!("UPDATE folders SET deleted_at = now() WHERE id = $1", [dump(a)])

      # A trashed row written before `folders_release_refs` can still name
      # the dead row (replayed with triggers off).
      Repo.query!("SET LOCAL session_replication_role = replica")
      Repo.query!("UPDATE notes SET folder_ref_id = $2 WHERE id = $1", [dump(n.id), dump(a)])
      Repo.query!("SET LOCAL session_replication_role = origin")

      Repo.query!("UPDATE notes SET deleted_at = NULL WHERE id = $1", [dump(n.id)])

      # Release D: `notes_folder_ref_live_only` fires on the restore and
      # NULLs the dead reference (the restore twin is gone), so the drain's
      # index finds the note and the FolderTable pass re-links it.
      assert ref(n) == nil
      FolderTable.run_pass(user_ids: [u.id])
      assert ref(n) == row_at(u, "A")
    end

    test "undoing a folder delete places notes that have no hash", %{user: u, vault: v} do
      n = note!(u, v, "Docs/In/n.md")
      op = Ecto.UUID.generate()
      {:ok, %{notes: 1}} = Folders.delete(u, v, "Docs", recursive: true, op_id: op)
      clear_hash!(n)

      assert {:ok, %{notes: 1}} = Folders.restore_op(u, v, op)
      assert ref(n) == row_at(u, "Docs/In")
    end
  end

  describe "FolderTable" do
    test "heals an unresolved note that has no hash", %{user: u, vault: v} do
      n = note!(u, v, "A/B/n.md")
      clear_hash!(n)
      Repo.query!("UPDATE notes SET folder_ref_id = NULL WHERE id = $1", [dump(n.id)])

      FolderTable.run_pass(user_ids: [u.id])

      assert ref(n) == row_at(u, "A/B")
    end

    test "control: a root note with no hash keeps no reference", %{user: u, vault: v} do
      n = note!(u, v, "top.md")
      clear_hash!(n)

      assert FolderTable.run_pass(user_ids: [u.id]) == :done
      assert ref(n) == nil
    end
  end

  describe "Canary" do
    defp folder_ref_drift, do: Canary.run().drift.folder_ref

    test "a note with no hash and a reference to another folder is drift", %{user: u, vault: v} do
      n = note!(u, v, "F/n.md")
      note!(u, v, "G/m.md")
      clear_hash!(n)

      Repo.query!("UPDATE notes SET folder_ref_id = $2 WHERE id = $1", [
        dump(n.id),
        dump(row_at(u, "G"))
      ])

      assert folder_ref_drift() == 1
    end

    test "control: a note with no hash and its own reference is not drift", %{user: u, vault: v} do
      n = note!(u, v, "F/n.md")
      clear_hash!(n)
      assert folder_ref_drift() == 0
    end
  end

  # `keep_stored_path/2`: a same-path write keeps the stored path and folder
  # envelopes (no re-encrypt, a HOT update). It compared the folder hash too,
  # so a stored NULL hash re-encrypted every write and wrote the hash back.
  test "a same-path write of a note with no hash keeps its folder envelope", %{
    user: u,
    vault: v
  } do
    n = note!(u, v, "A/n.md")
    clear_hash!(n)

    %{rows: [[nonce]]} =
      Repo.query!("SELECT folder_nonce FROM notes WHERE id = $1", [dump(n.id)])

    {:ok, _} =
      Notes.upsert_note(u, v, %{"path" => "A/n.md", "content" => "# T\n\nv2"}, actor: "api")

    assert %{rows: [[^nonce, nil]]} =
             Repo.query!("SELECT folder_nonce, folder_hmac FROM notes WHERE id = $1", [
               dump(n.id)
             ])
  end
end
