defmodule Engram.Folders.FolderRefTriggerTest do
  # `notes_set_folder_ref`: a write that lists only `folder_hmac` (what the
  # previous release does) gets its `folder_ref_id`.
  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.Notes
  alias Engram.Repo

  setup do
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    {:ok, filter_key} = Crypto.dek_filter_key(user)
    %{user: user, vault: vault, fk: filter_key}
  end

  defp dump(id), do: Ecto.UUID.dump!(id)
  defp hmac(fk, text), do: Crypto.hmac_field(fk, text)

  defp folder!(user, vault, name_hmac, opts),
    do: Engram.FolderRows.insert!(user, vault, name_hmac, opts)

  # The previous release's write: only the stored columns, no folder row.
  defp old_release_write!(user, vault, path),
    do: Engram.Fixtures.insert_note!(user, vault, %{path: path, content: "# T\n\nbody"})

  defp write!(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "# T\n\nbody"}, actor: "api")

    note
  end

  defp folder_ref(note_id) do
    %{rows: [[ref]]} =
      Repo.query!("SELECT folder_ref_id FROM notes WHERE id = $1", [dump(note_id)])

    ref && Ecto.UUID.load!(ref)
  end

  describe "notes_set_folder_ref trigger" do
    test "a write that sets only folder_hmac gets its folder_ref_id", %{user: u, vault: v, fk: fk} do
      f = folder!(u, v, hmac(fk, "Dir"), full_path_hmac: hmac(fk, "Dir"))

      # What the previous release does: it knows nothing of folder_ref_id.
      note = write!(u, v, "Dir/A.md")
      assert folder_ref(note.id) == f

      # A move to a folder with no row clears it; a move back restores it.
      Repo.query!("UPDATE notes SET folder_hmac = $1 WHERE id = $2", [
        hmac(fk, "Elsewhere"),
        dump(note.id)
      ])

      assert folder_ref(note.id) == nil

      Repo.query!("UPDATE notes SET folder_hmac = $1 WHERE id = $2", [
        hmac(fk, "Dir"),
        dump(note.id)
      ])

      assert folder_ref(note.id) == f
    end

    test "a folder with no row, the root, another vault's folder and a tombstone stay NULL", %{
      user: u,
      vault: v,
      fk: fk
    } do
      other = insert(:vault, user: u)
      folder!(u, other, hmac(fk, "Other"), full_path_hmac: hmac(fk, "Other"))

      folder!(u, v, hmac(fk, "Gone"),
        full_path_hmac: hmac(fk, "Gone"),
        deleted_at: ~U[2026-10-27 00:00:00Z]
      )

      for path <- ["Nobody/A.md", "Root.md", "Other/B.md", "Gone/C.md"] do
        assert folder_ref(old_release_write!(u, v, path).id) == nil, path
      end
    end

    test "a folder marker row is not given a reference", %{user: u, vault: v, fk: fk} do
      folder!(u, v, hmac(fk, "Dir"), full_path_hmac: hmac(fk, "Dir"))
      {:ok, marker} = Notes.create_folder_marker(u, v, "Dir")

      assert folder_ref(marker.id) == nil
    end

    test "setting only folder_ref_id fires no trigger (no loop, no derived-key rewrite)", %{
      user: u,
      vault: v,
      fk: fk
    } do
      f = folder!(u, v, hmac(fk, "Dir"), full_path_hmac: hmac(fk, "Dir"))
      note = write!(u, v, "Dir/A.md")
      assert folder_ref(note.id) == f

      # notes_set_folder_ref would put `f` back if it fired on this statement.
      Repo.query!("UPDATE notes SET folder_ref_id = NULL WHERE id = $1", [dump(note.id)])
      assert folder_ref(note.id) == nil
    end

    test "hard-deleting a folder nulls the reference, not the vault", %{user: u, vault: v, fk: fk} do
      f = folder!(u, v, hmac(fk, "Dir"), full_path_hmac: hmac(fk, "Dir"))
      note = write!(u, v, "Dir/A.md")
      assert folder_ref(note.id) == f

      Repo.query!("DELETE FROM folders WHERE id = $1", [dump(f)])
      assert folder_ref(note.id) == nil
    end
  end
end
