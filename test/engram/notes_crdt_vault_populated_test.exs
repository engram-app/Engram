defmodule Engram.NotesCrdtVaultPopulatedTest do
  @moduledoc """
  `vault_populated` is what the web /link success page waits on before
  forwarding the user to their vault.

  It used to be broadcast only from the REST upsert and batch paths. The
  Obsidian plugin does not use either — it creates notes over the CRDT
  channel (`crdt_create` -> `genesis_crdt_note`) — so for the exact scenario
  the page was built for, an Obsidian first sync, the event never fired and
  the page waited forever.
  """
  use Engram.DataCase, async: false

  alias Engram.Notes

  setup do
    user = insert(:user)
    vault = insert(:vault, user: user)
    EngramWeb.Endpoint.subscribe("user:#{user.id}")
    {:ok, user: user, vault: vault}
  end

  test "a crdt genesis create in an empty vault announces vault_populated", %{
    user: user,
    vault: vault
  } do
    id = Ecto.UUID.generate()
    {:ok, _note} = Notes.genesis_crdt_note(user, vault, id, "First Note.md")

    assert_receive %Phoenix.Socket.Broadcast{
      event: "vault_populated",
      payload: %{vault_id: broadcast_vault_id}
    }

    assert broadcast_vault_id == vault.id
  end

  # The probe counts NOTES, and folder markers live in the same table. The
  # plugin's catch-up seeds a folder row for every empty local folder BEFORE
  # it pushes any note, so this is the ordinary first sync, not a corner: a
  # bare `scoped/2` probe saw 2 rows, stayed silent, and stranded the web
  # page on a `note_count` that was still 0.
  test "a folder marker does not count as a note", %{user: user, vault: vault} do
    {:ok, _marker} = Notes.create_folder_marker(user, vault, "Empty Folder")

    {:ok, _note} = Notes.genesis_crdt_note(user, vault, Ecto.UUID.generate(), "First Note.md")

    assert_receive %Phoenix.Socket.Broadcast{event: "vault_populated"}
  end

  # Same class, other predicate: a deleted note is invisible to the counter
  # the page gates on, so it must be invisible to the probe too.
  test "a tombstoned note does not count", %{user: user, vault: vault} do
    {:ok, gone} = Notes.genesis_crdt_note(user, vault, Ecto.UUID.generate(), "Gone.md")
    assert_receive %Phoenix.Socket.Broadcast{event: "vault_populated"}
    # Tombstone the row directly: what the probe must ignore is the row STATE,
    # and going through the delete API would drag its own path-lookup and
    # tenant plumbing into a test about a WHERE clause.
    {1, _} =
      Ecto.Query.from(n in Notes.Note, where: n.id == ^gone.id)
      |> Engram.Repo.update_all([set: [deleted_at: DateTime.utc_now()]], skip_tenant_check: true)

    {:ok, _note} = Notes.genesis_crdt_note(user, vault, Ecto.UUID.generate(), "Fresh.md")

    assert_receive %Phoenix.Socket.Broadcast{event: "vault_populated"}
  end

  # The listener is one-shot and the event means "this vault stopped being
  # empty", so later creates must stay quiet — otherwise every note in a
  # first sync fans out a redundant broadcast to every connected client.
  test "a second create does not announce again", %{user: user, vault: vault} do
    {:ok, _} = Notes.genesis_crdt_note(user, vault, Ecto.UUID.generate(), "First Note.md")
    assert_receive %Phoenix.Socket.Broadcast{event: "vault_populated"}

    {:ok, _} = Notes.genesis_crdt_note(user, vault, Ecto.UUID.generate(), "Second Note.md")
    refute_receive %Phoenix.Socket.Broadcast{event: "vault_populated"}, 200
  end
end
