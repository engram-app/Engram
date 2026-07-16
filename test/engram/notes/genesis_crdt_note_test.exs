defmodule Engram.Notes.GenesisCrdtNoteTest do
  use Engram.DataCase, async: false
  alias Engram.{Crypto, Notes, Vaults}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "GenesisTest"})
    %{user: user, vault: vault}
  end

  test "creates a bare empty-content row for a new id + path", %{user: user, vault: vault} do
    id = Ecto.UUID.generate()
    assert {:ok, note} = Notes.genesis_crdt_note(user, vault, id, "Notes/new.md")
    assert note.id == id
    assert note.content == ""
    # resolves by path (Phase-B path fields valid)
    assert {:ok, ^id} = fetch_id_by_path(user, vault, "Notes/new.md")
  end

  defp fetch_id_by_path(user, vault, path) do
    case Notes.get_note(user, vault, path) do
      {:ok, n} -> {:ok, n.id}
      other -> other
    end
  end
end
