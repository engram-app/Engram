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
