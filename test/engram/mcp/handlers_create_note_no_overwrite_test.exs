defmodule Engram.MCP.HandlersCreateNoteNoOverwriteTest do
  # create_note advertises destructiveHint: false, so clients may run it without
  # a confirmation prompt. It used to upsert, silently replacing a user's note
  # that happened to share the derived `folder/title.md` path.
  use Engram.DataCase, async: true

  alias Engram.MCP.Handlers
  alias Engram.Notes

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  test "refuses a path that already holds a note, leaving it untouched",
       %{user: user, vault: vault} do
    {:ok, _} =
      Notes.upsert_note(user, vault, %{
        "path" => "Projects/Meeting Notes.md",
        "content" => "# Meeting Notes\n\nwritten by the user",
        "mtime" => 1.0
      })

    assert {:error, msg} =
             Handlers.handle("create_note", user, vault, %{
               "title" => "Meeting Notes",
               "content" => "model text",
               "suggested_folder" => "Projects"
             })

    assert msg =~ "already exists"
    assert msg =~ "Projects/Meeting Notes.md"

    {:ok, note} = Notes.get_note(user, vault, "Projects/Meeting Notes.md")
    assert note.content =~ "written by the user"
    refute note.content =~ "model text"
  end

  test "matches the stored path after sanitization", %{user: user, vault: vault} do
    {:ok, stored} =
      Notes.upsert_note(user, vault, %{
        "path" => "Projects/What?.md",
        "content" => "# What?\n\noriginal",
        "mtime" => 1.0
      })

    assert {:error, _} =
             Handlers.handle("create_note", user, vault, %{
               "title" => "What?",
               "content" => "model text",
               "suggested_folder" => "Projects"
             })

    {:ok, note} = Notes.get_note(user, vault, stored.path)
    assert note.content =~ "original"
  end

  test "still creates a note at a free path", %{user: user, vault: vault} do
    assert {:ok, _, %{"path" => "Projects/New.md"}} =
             Handlers.handle("create_note", user, vault, %{
               "title" => "New",
               "content" => "fresh",
               "suggested_folder" => "Projects"
             })
  end
end
