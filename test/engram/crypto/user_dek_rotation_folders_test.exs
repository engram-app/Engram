defmodule Engram.Crypto.UserDekRotationFoldersTest do
  # A DEK rotation re-keys `folders` like every other encrypted table: the
  # name envelope, `name_hmac` and `full_path_hmac`. Without it the
  # `notes_set_folder_ref` trigger, firing when the notes sweep rewrites
  # `folder_hmac`, resolves no folder row and NULLs `folder_ref_id`.
  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.Crypto.{Envelope, UserDekRotation}
  alias Engram.DataMigrations.FolderTable
  alias Engram.Folders.Folder
  alias Engram.Notes
  alias Engram.Repo

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    Bypass.stub(bypass, "POST", "/collections/engram_notes/points/scroll", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"result" => %{"points" => [], "next_page_offset" => nil}})
      )
    end)

    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "FolderRotation", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp write!(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "# T\n\nbody"}, actor: "api")

    note
  end

  defp folders(user_id) do
    Repo.all(from(f in Folder, where: f.user_id == ^user_id, order_by: f.id),
      skip_tenant_check: true
    )
  end

  defp ref_id(note_id),
    do:
      Repo.query!("SELECT folder_ref_id FROM notes WHERE id = $1", [Ecto.UUID.dump!(note_id)]).rows
      |> hd()
      |> hd()

  test "rotation re-keys folder names and hmacs, and notes keep resolving their folder", %{
    user: user,
    vault: vault
  } do
    note = write!(user, vault, "Projects/Alpha/one.md")
    deep = write!(user, vault, "Projects/Alpha/Beta/Gamma/Delta/two.md")
    root_note = write!(user, vault, "top.md")
    trashed = write!(user, vault, "Old/Gone/three.md")
    FolderTable.run_pass(user_ids: [user.id])

    # A soft-deleted folder with a trashed note in it.
    Repo.query!(
      "UPDATE folders SET deleted_at = now() WHERE id = (SELECT folder_ref_id FROM notes WHERE id = $1)",
      [Ecto.UUID.dump!(trashed.id)]
    )

    Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [Ecto.UUID.dump!(trashed.id)])

    before = folders(user.id)
    assert length(before) == 7
    deep_before = ref_id(deep.id)
    ref_before = ref_id(note.id)
    assert ref_before
    assert ref_id(root_note.id) == nil

    assert :ok = UserDekRotation.rotate_user(user.id)

    user = Engram.Accounts.get_user_uncached(user.id)
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, fk} = Crypto.dek_filter_key(user)
    after_rows = folders(user.id)

    assert Enum.map(after_rows, & &1.id) == Enum.map(before, & &1.id)

    by_name =
      Map.new(after_rows, fn f ->
        {:ok, name} =
          Envelope.decrypt(
            f.name_ciphertext,
            f.name_nonce,
            dek,
            Crypto.aad_for_row(:folders, :name, f.id)
          )

        assert f.name_hmac == Folder.name_hmac(fk, name)
        {name, f}
      end)

    assert by_name["Gamma"].full_path_hmac ==
             Crypto.hmac_field(fk, "Projects/Alpha/Beta/Gamma")

    assert by_name["Gone"].full_path_hmac == Crypto.hmac_field(fk, "Old/Gone")
    assert by_name["Gone"].deleted_at
    assert by_name["Projects"].full_path_hmac == Crypto.hmac_field(fk, "Projects")
    assert by_name["Alpha"].full_path_hmac == Crypto.hmac_field(fk, "Projects/Alpha")

    # The trigger found the re-keyed row: same folder, no orphan, no duplicate.
    assert ref_id(note.id) == Ecto.UUID.dump!(by_name["Alpha"].id)
    assert ref_id(deep.id) == deep_before
    assert ref_id(root_note.id) == nil

    # A trashed note in a soft-deleted folder loses its ref: the
    # `notes_set_folder_ref` trigger resolves live folders only, and it fires
    # on the `folder_hmac` rewrite. Nothing reads the ref yet, and the note
    # re-enters `FolderTable`'s selection (live, ref NULL) when it is restored.
    assert ref_id(trashed.id) == nil

    Repo.query!("UPDATE folders SET deleted_at = NULL WHERE id = $1", [
      Ecto.UUID.dump!(by_name["Gone"].id)
    ])

    Repo.query!("UPDATE notes SET deleted_at = NULL WHERE id = $1", [Ecto.UUID.dump!(trashed.id)])
    FolderTable.run_pass(user_ids: [user.id])
    assert ref_id(trashed.id) == Ecto.UUID.dump!(by_name["Gone"].id)

    # A second pass over the data migration has nothing to do (no duplicate tree).
    assert :done = FolderTable.run_pass(user_ids: [user.id])
    assert length(folders(user.id)) == 7
  end

  test "a looping parent chain does not hang or fail the rotation", %{user: user, vault: vault} do
    write!(user, vault, "P/Q/n.md")
    FolderTable.run_pass(user_ids: [user.id])
    [a, b] = folders(user.id)

    Repo.query!("UPDATE folders SET parent_id = $2 WHERE id = $1", [
      Ecto.UUID.dump!(a.id),
      Ecto.UUID.dump!(b.id)
    ])

    Repo.query!("UPDATE folders SET parent_id = $2 WHERE id = $1", [
      Ecto.UUID.dump!(b.id),
      Ecto.UUID.dump!(a.id)
    ])

    assert :ok = UserDekRotation.rotate_user(user.id)
  end
end
