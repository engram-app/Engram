defmodule Engram.FolderMarkerTombstonesTest do
  # A folder name can hold one live marker and any number of tombstones with
  # the same folder_hmac: the unique index only covers live markers, and a
  # rename onto a deleted name moves the old marker in place beside the
  # name's tombstone. Every marker lookup must prefer the live row, else the
  # newest tombstone (#2121: folder delete raised MultipleResultsError).
  use Engram.DataCase, async: true

  alias Engram.Notes

  # The factory user has no DEK, and delete_folder_marker/3 (unlike create)
  # does not mint one, so it needs a user that already holds it.
  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  # GateG deleted, then GateF renamed onto it: one live GateG marker (the
  # moved GateF row) plus GateG's tombstone. The staging #2121 pair.
  defp rename_onto_tombstone!(user, vault) do
    {:ok, _} = Notes.create_folder_marker(user, vault, "GateG")
    {:ok, :deleted} = Notes.delete_folder_marker(user, vault, "GateG")
    {:ok, moved} = Notes.create_folder_marker(user, vault, "GateF")
    {:ok, _} = Notes.rename_folder(user, vault, "GateF", "GateG")
    moved
  end

  test "deleting a folder renamed onto a tombstoned name deletes the live marker", %{
    user: user,
    vault: vault
  } do
    rename_onto_tombstone!(user, vault)

    assert {:ok, :deleted} = Notes.delete_folder_marker(user, vault, "GateG")
    assert {:ok, :not_found} = Notes.delete_folder_marker(user, vault, "GateG")
  end

  test "re-creating that folder returns the live marker, not a new one", %{
    user: user,
    vault: vault
  } do
    moved = rename_onto_tombstone!(user, vault)

    assert {:ok, marker} = Notes.create_folder_marker(user, vault, "GateG")
    assert marker.id == moved.id
    assert marker.deleted_at == nil
  end

  test "with only tombstones, re-create revives the newest one", %{user: user, vault: vault} do
    moved = rename_onto_tombstone!(user, vault)
    {:ok, :deleted} = Notes.delete_folder_marker(user, vault, "GateG")

    assert {:ok, revived} = Notes.create_folder_marker(user, vault, "GateG")
    assert revived.id == moved.id
    assert revived.deleted_at == nil
  end
end
