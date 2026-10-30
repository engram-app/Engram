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
    root_note = write!(user, vault, "top.md")
    FolderTable.run_pass(user_ids: [user.id])

    before = folders(user.id)
    assert length(before) == 2
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

    assert by_name["Projects"].full_path_hmac == Crypto.hmac_field(fk, "Projects")
    assert by_name["Alpha"].full_path_hmac == Crypto.hmac_field(fk, "Projects/Alpha")

    # The trigger found the re-keyed row: same folder, no orphan, no duplicate.
    assert ref_id(note.id) == Ecto.UUID.dump!(by_name["Alpha"].id)
    assert ref_id(root_note.id) == nil

    # A second pass over the data migration has nothing to do (no duplicate tree).
    assert :done = FolderTable.run_pass(user_ids: [user.id])
    assert length(folders(user.id)) == 2
  end
end
