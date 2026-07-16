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

  test "a malformed id is rejected, no note created", %{user: user, vault: vault} do
    assert {:error, :invalid_id} = Notes.genesis_crdt_note(user, vault, "not-a-uuid", "Notes/bad.md")
    assert {:error, :not_found} = Notes.get_note(user, vault, "Notes/bad.md")
  end

  test "id already live at the requested path is an idempotent no-op, content untouched", %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Notes/a.md", "content" => "hello"})
    assert {:ok, got} = Notes.genesis_crdt_note(user, vault, note.id, "Notes/a.md")
    assert got.id == note.id
    assert got.content == "hello"                       # content preserved
  end

  test "path owned by a live note under a different id adopts that id, content untouched", %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Notes/b.md", "content" => "world"})
    other = Ecto.UUID.generate()
    assert {:ok, got} = Notes.genesis_crdt_note(user, vault, other, "Notes/b.md")
    assert got.id == note.id                            # adopted the server's id
    refute Notes.note_in_vault?(user, vault.id, other)
    {:ok, still} = Notes.get_note(user, vault, "Notes/b.md")
    assert still.content == "world"                     # untouched
  end

  test "id live at a different path is an id_conflict, neither note changes", %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Notes/c.md", "content" => "keep"})
    assert {:error, :id_conflict, live} = Notes.genesis_crdt_note(user, vault, note.id, "Notes/elsewhere.md")
    assert live.id == note.id
    {:ok, still} = Notes.get_note(user, vault, "Notes/c.md")
    assert still.content == "keep"
    assert {:error, :not_found} = Notes.get_note(user, vault, "Notes/elsewhere.md")
  end

  defp fetch_id_by_path(user, vault, path) do
    case Notes.get_note(user, vault, path) do
      {:ok, n} -> {:ok, n.id}
      other -> other
    end
  end
end
