defmodule Engram.MCP.HandlersEchoStoredPathTest do
  @moduledoc """
  Write replies must name where the note actually landed. The handlers echoed
  the raw argument, so `a/../b.md` came back as written while the note was
  stored at `a/b.md`, and a follow-up get_notes on the echoed path missed.
  Found by staging validation, 2026-10-19.
  """
  use Engram.DataCase, async: true

  alias Engram.MCP.Handlers
  alias Engram.Notes

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  test "write_note echoes the stored path", %{user: user, vault: vault} do
    assert {:ok, text, %{"path" => "a/b.md"}} =
             Handlers.handle("write_note", user, vault, %{"path" => "a/../b.md", "content" => "x"})

    assert text == "Note saved: a/b.md"
    assert Notes.note_exists?(user, vault, "a/b.md")
  end

  test "create_note echoes the stored path", %{user: user, vault: vault} do
    assert {:ok, text, %{"path" => "a/x/c.md"}} =
             Handlers.handle("create_note", user, vault, %{
               "title" => "c",
               "suggested_folder" => "a/../x",
               "content" => "x"
             })

    assert text == "Note created: a/x/c.md"
  end

  test "rename_note echoes the stored new path", %{user: user, vault: vault} do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "d.md", "content" => "x"}, actor: "api")

    assert {:ok, text, %{"new_path" => "a/e.md"}} =
             Handlers.handle("rename_note", user, vault, %{
               "old_path" => "d.md",
               "new_path" => "a/../e.md"
             })

    assert text == "Note renamed: d.md -> a/e.md"
  end

  test "rename_folder echoes the stored new folder", %{user: user, vault: vault} do
    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "f/g.md", "content" => "x"}, actor: "api")

    assert {:ok, text, %{"new_folder" => "h/sub"}} =
             Handlers.handle("rename_folder", user, vault, %{
               "old_folder" => "f",
               "new_folder" => "h/%2e%2e/sub"
             })

    assert text =~ "Folder renamed: f -> h/sub "
  end

  test "append_to_note on a dotted path appends to the stored note", %{user: user, vault: vault} do
    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "a/b.md", "content" => "keep me"}, actor: "api")

    assert {:ok, _text, %{"path" => "a/b.md"}} =
             Handlers.handle("append_to_note", user, vault, %{
               "path" => "a/../b.md",
               "text" => "more"
             })

    {:ok, note} = Notes.get_note(user, vault, "a/b.md")
    assert note.content =~ "keep me"
    assert note.content =~ "more"
  end

  test "append_to_note creating a note echoes the stored path", %{user: user, vault: vault} do
    assert {:ok, text, %{"path" => "a/n.md", "created" => true}} =
             Handlers.handle("append_to_note", user, vault, %{
               "path" => "a/../n.md",
               "text" => "x"
             })

    assert text =~ "a/n.md"
  end

  test "rename_note conflict names the stored path", %{user: user, vault: vault} do
    for p <- ["d.md", "a/e.md"],
        do:
          {:ok, _} =
            Notes.upsert_note(user, vault, %{"path" => p, "content" => "x"}, actor: "api")

    assert {:error, {:path_conflict, msg}} =
             Handlers.handle("rename_note", user, vault, %{
               "old_path" => "d.md",
               "new_path" => "a/../e.md"
             })

    assert msg == "Note rename conflict: a/e.md is already taken"
  end

  # Rows written before #2005 can hold an unsanitized path (folder renames
  # stored the target verbatim). append_to_note must still reach them.
  test "append_to_note reaches a legacy unsanitized path", %{user: user, vault: vault} do
    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "f/x.md", "content" => "legacy"}, actor: "api")

    {:ok, _} = Notes.rename_folder(user, vault, "f", "My  Folder")
    assert {:ok, _} = Notes.get_note(user, vault, "My  Folder/x.md")

    # The append lands on the legacy row (no duplicate), and the write moves it
    # to its sanitized path, which the reply names.
    assert {:ok, _text, %{"path" => "My Folder/x.md", "created" => false}} =
             Handlers.handle("append_to_note", user, vault, %{
               "path" => "My  Folder/x.md",
               "text" => "more"
             })

    {:ok, note} = Notes.get_note(user, vault, "My Folder/x.md")
    assert note.content =~ "legacy"
    assert note.content =~ "more"
    assert {:error, :not_found} = Notes.get_note(user, vault, "My  Folder/x.md")
  end
end
