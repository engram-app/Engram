defmodule Engram.NotesFolderMarkerTest do
  use Engram.DataCase, async: true

  alias Engram.Notes

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  describe "create_folder_marker/3" do
    test "creates a kind='folder' row with encrypted folder name", %{user: user, vault: vault} do
      assert {:ok, marker} = Notes.create_folder_marker(user, vault, "Projects/Active")

      assert marker.kind == "folder"
      assert marker.folder == "Projects/Active"
      assert is_binary(marker.folder_ciphertext)
      assert is_binary(marker.folder_nonce)
      assert is_binary(marker.folder_hmac)
      assert is_nil(marker.path_ciphertext)
      assert is_nil(marker.content_ciphertext)
      assert is_nil(marker.title_ciphertext)
      assert is_nil(marker.tags_ciphertext)
    end

    test "is idempotent — second call returns the existing row", %{user: user, vault: vault} do
      {:ok, a} = Notes.create_folder_marker(user, vault, "Projects")
      {:ok, b} = Notes.create_folder_marker(user, vault, "Projects")
      assert a.id == b.id
    end

    test "rejects root path", %{user: user, vault: vault} do
      assert {:error, :root_folder_not_marker} = Notes.create_folder_marker(user, vault, "")
    end

    test "undeletes a soft-deleted marker on re-create", %{user: user, vault: vault} do
      {:ok, m1} = Notes.create_folder_marker(user, vault, "Trash")
      {:ok, _} = Notes.delete_folder_marker(user, vault, "Trash")

      {:ok, m2} = Notes.create_folder_marker(user, vault, "Trash")
      assert m2.id == m1.id
      assert is_nil(m2.deleted_at)
    end
  end

  describe "delete_folder_marker/3" do
    test "soft-deletes an existing marker", %{user: user, vault: vault} do
      {:ok, marker} = Notes.create_folder_marker(user, vault, "Doomed")
      assert {:ok, :deleted} = Notes.delete_folder_marker(user, vault, "Doomed")

      {:ok, refreshed} =
        Engram.Repo.with_tenant(user.id, fn ->
          Engram.Repo.get!(Engram.Notes.Note, marker.id)
        end)

      refute is_nil(refreshed.deleted_at)
    end

    test "returns :not_found when no marker exists (idempotent caller-side)",
         %{user: user, vault: vault} do
      assert {:ok, :not_found} = Notes.delete_folder_marker(user, vault, "Ghost")
    end

    test "does not touch real notes under the same folder path",
         %{user: user, vault: vault} do
      {:ok, _note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Real/note.md",
          "content" => "body",
          "mtime" => 1.0
        })

      {:ok, _marker} = Notes.create_folder_marker(user, vault, "Real")
      {:ok, :deleted} = Notes.delete_folder_marker(user, vault, "Real")

      {:ok, notes} = Notes.list_notes_in_folder(user, vault, "Real")
      assert length(notes) == 1
    end
  end
end
