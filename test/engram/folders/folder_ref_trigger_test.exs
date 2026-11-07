defmodule Engram.Folders.FolderRefTriggerTest do
  # `notes.folder_ref_id` once `notes_set_folder_ref` is dropped (R9 release
  # D): writers set it, the foreign key nulls it on a hard folder delete.
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

  describe "after the R9 release D contract" do
    test "notes_set_folder_ref, its restore twin and their function are gone" do
      %{rows: [[triggers]]} =
        Repo.query!("""
        SELECT count(*)::int FROM pg_trigger
        WHERE tgrelid = 'public.notes'::regclass
          AND tgname IN ('notes_set_folder_ref', 'notes_set_folder_ref_on_restore')
        """)

      %{rows: [[functions]]} =
        Repo.query!("SELECT count(*)::int FROM pg_proc WHERE proname = 'notes_set_folder_ref'")

      assert {triggers, functions} == {0, 0}
    end

    # The writer sets the reference, not the database: a raw hash write
    # (what no release does any more) leaves it alone.
    test "a write that sets only folder_hmac keeps the stored reference", %{
      user: u,
      vault: v,
      fk: fk
    } do
      f = folder!(u, v, hmac(fk, "Dir"), full_path_hmac: hmac(fk, "Dir"))
      note = write!(u, v, "Dir/A.md")
      assert folder_ref(note.id) == f

      Repo.query!("UPDATE notes SET folder_hmac = $1 WHERE id = $2", [
        hmac(fk, "Elsewhere"),
        dump(note.id)
      ])

      assert folder_ref(note.id) == f
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

    # #2413 / owner rule (a note never leaves a folder listing): a raw restore
    # of a note whose folder row died must not leave a live note naming the
    # dead row, which no listing places and the drain's index
    # (`notes_unresolved_folder`, NULL references only) cannot find.
    test "a raw restore NULLs a reference to a dead folder row; the drain re-links it", %{
      user: u,
      vault: v
    } do
      note = write!(u, v, "Gone/A.md")
      dead = folder_ref(note.id)
      assert dead

      Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [dump(note.id)])
      # A row written before `folders_release_refs`: the trashed note still
      # names the row when it dies (replayed with triggers off).
      Repo.query!("SET LOCAL session_replication_role = replica")
      Repo.query!("UPDATE folders SET deleted_at = now() WHERE id = $1", [dump(dead)])
      Repo.query!("SET LOCAL session_replication_role = origin")
      assert folder_ref(note.id) == dead

      Repo.query!("UPDATE notes SET deleted_at = NULL WHERE id = $1", [dump(note.id)])
      assert folder_ref(note.id) == nil

      %{rows: [[unresolved]]} =
        Repo.query!(
          "SELECT count(*)::int FROM notes WHERE id = $1 AND " <>
            Engram.Folders.Drift.notes_unresolved_sql(),
          [dump(note.id)]
        )

      assert unresolved == 1

      Engram.DataMigrations.FolderTable.run_pass(user_ids: [u.id])
      relinked = folder_ref(note.id)
      assert relinked && relinked != dead
    end

    test "a delete or an ordinary save does not touch the reference", %{user: u, vault: v} do
      note = write!(u, v, "Keep/A.md")
      ref = folder_ref(note.id)
      Repo.query!("UPDATE notes SET folder_ref_id = NULL WHERE id = $1", [dump(note.id)])
      Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [dump(note.id)])
      assert folder_ref(note.id) == nil
      assert ref
    end
  end
end
