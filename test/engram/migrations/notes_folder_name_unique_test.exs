defmodule Engram.Migrations.NotesFolderNameUniqueTest do
  # S6 step 2 (Engram#2523): `notes_folder_name_unique` refuses a second live
  # note with the same exact name in the same folder row, and only that.
  use Engram.DataCase, async: true

  alias Engram.Notes

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp note!(u, v, path) do
    {:ok, n} = Notes.upsert_note(u, v, %{"path" => path, "content" => "x"}, actor: "api")
    n
  end

  # Gives `b` `a`'s name keys (its folder is already `a`'s): what a writer
  # that ignored the name would leave.
  defp copy_name!(a, b) do
    Repo.query!(
      "UPDATE notes SET name_hmac = s.name_hmac, name_ci_hmac = s.name_ci_hmac " <>
        "FROM notes s WHERE s.id = $1 AND notes.id = $2",
      [Ecto.UUID.dump!(a.id), Ecto.UUID.dump!(b.id)]
    )
  end

  test "a second live note with the same name in one folder is refused", %{user: u, vault: v} do
    a = note!(u, v, "F/x.md")
    b = note!(u, v, "F/y.md")

    assert_raise Postgrex.Error, ~r/notes_folder_name_unique/, fn -> copy_name!(a, b) end
  end

  test "other folders, other case, tombstones and unkeyed rows are not refused", ctx do
    %{user: u, vault: v} = ctx
    note!(u, v, "F/x.md")
    note!(u, v, "G/x.md")
    note!(u, v, "F/X.md")
    a = note!(u, v, "F/a.md")
    gone = note!(u, v, "F/b.md")
    :ok = Notes.delete_note(u, v, "F/b.md")
    copy_name!(a, gone)

    # A NULL reference (no name key) is out of the index.
    stale = note!(u, v, "F/c.md")

    Repo.query!("UPDATE notes SET folder_ref_id = NULL WHERE id = $1", [Ecto.UUID.dump!(stale.id)])

    copy_name!(a, stale)
  end
end
