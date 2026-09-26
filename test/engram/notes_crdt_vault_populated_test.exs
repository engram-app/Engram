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

  # Every vault created through /link or the web app is seeded with the
  # welcome note first (`Engram.Vaults.WelcomeNote`). It is note #1 but must not
  # count: otherwise the plugin's first real note is #2, the 0->1 probe never
  # sees it, and the /link success page waits forever (staging, 2026-09-25).
  describe "with the welcome note seeded" do
    setup %{user: user, vault: vault} do
      # The controllers that seed always hold a user with a DEK; so must this.
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      :ok = Engram.Vaults.WelcomeNote.seed(user, vault)
      # `seed/2` swallows every failure and returns :ok. Without this, a seed
      # that silently wrote nothing would let every test below pass vacuously.
      assert {:ok, _} = Notes.get_note(user, vault, Engram.Vaults.WelcomeNote.path())
      {:ok, user: user}
    end

    test "seeding it does not announce", _ctx do
      refute_receive %Phoenix.Socket.Broadcast{event: "vault_populated"}, 200
    end

    test "the first real crdt note announces", %{user: user, vault: vault} do
      {:ok, _} = Notes.genesis_crdt_note(user, vault, Ecto.UUID.generate(), "First Note.md")

      assert_receive %Phoenix.Socket.Broadcast{
        event: "vault_populated",
        payload: %{vault_id: vault_id}
      }

      assert vault_id == vault.id
    end

    test "the first real batch upsert announces", %{user: user, vault: vault} do
      {:ok, _} =
        Notes.batch_upsert_notes(user, vault, [
          %{"path" => "first.md", "content" => "x", "mtime" => 1.0}
        ])

      assert_receive %Phoenix.Socket.Broadcast{event: "vault_populated"}
    end

    test "the second real note stays quiet", %{user: user, vault: vault} do
      {:ok, _} = Notes.genesis_crdt_note(user, vault, Ecto.UUID.generate(), "First Note.md")
      assert_receive %Phoenix.Socket.Broadcast{event: "vault_populated"}

      {:ok, _} = Notes.genesis_crdt_note(user, vault, Ecto.UUID.generate(), "Second Note.md")
      refute_receive %Phoenix.Socket.Broadcast{event: "vault_populated"}, 200
    end
  end

  # A device can re-push a `Welcome to Engram.md` of its own after the user
  # deleted the seed. That is not the vault's first real note, so the batch
  # path must stay quiet exactly like the CRDT path, and fire on the next one.
  test "a batch holding only the welcome path does not announce", %{user: user, vault: vault} do
    {:ok, _} =
      Notes.batch_upsert_notes(user, vault, [
        %{"path" => Engram.Vaults.WelcomeNote.path(), "content" => "mine", "mtime" => 1.0}
      ])

    refute_receive %Phoenix.Socket.Broadcast{event: "vault_populated"}, 200

    {:ok, _} =
      Notes.batch_upsert_notes(user, vault, [
        %{"path" => "first.md", "content" => "x", "mtime" => 1.0}
      ])

    assert_receive %Phoenix.Socket.Broadcast{event: "vault_populated"}
  end
end
