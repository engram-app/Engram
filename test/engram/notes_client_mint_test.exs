defmodule Engram.NotesClientMintTest do
  # Phase I — contract: when a caller (plugin, SDK, e2e) supplies an `id` in
  # the upsert_note attrs, the server persists it as the row's PK. Falls back
  # to server-side mint when the supplied id is missing or malformed.
  use Engram.DataCase, async: false

  import Engram.Factory

  test "upsert_note honors client-supplied uuidv7 id" do
    user = insert(:user)
    vault = insert(:vault, user: user)
    client_minted = UUIDv7.generate()

    {:ok, note} =
      Engram.Notes.upsert_note(user, vault, %{
        "id" => client_minted,
        "path" => "/client-mint.md",
        "content" => "hello"
      })

    assert note.id == client_minted
  end

  test "upsert_note falls back to server mint on malformed client id" do
    user = insert(:user)
    vault = insert(:vault, user: user)

    {:ok, note} =
      Engram.Notes.upsert_note(user, vault, %{
        "id" => "not-a-uuid",
        "path" => "/server-mint.md",
        "content" => "hello"
      })

    assert {:ok, _} = Ecto.UUID.cast(note.id)
    refute note.id == "not-a-uuid"
  end

  test "upsert_note server-mints when no client id supplied" do
    user = insert(:user)
    vault = insert(:vault, user: user)

    {:ok, note} =
      Engram.Notes.upsert_note(user, vault, %{
        "path" => "/no-client-id.md",
        "content" => "hello"
      })

    assert is_binary(note.id)
    assert {:ok, _} = Ecto.UUID.cast(note.id)
  end
end
