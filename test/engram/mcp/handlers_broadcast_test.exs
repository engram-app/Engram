defmodule Engram.MCP.HandlersBroadcastTest do
  @moduledoc """
  MCP write tools route through Notes.upsert_note — but until now nothing
  asserted they produce the same note_changed fan-out as a plugin REST push.
  A silent divergence on the MCP path (no broadcast) was green. These tests
  make every MCP write tool prove its delivery side effect.
  """
  use Engram.DataCase, async: true

  alias Engram.MCP.Handlers
  alias Engram.Notes

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
    %{user: user, vault: vault}
  end

  test "create_note broadcasts note_changed with content", %{user: user, vault: vault} do
    # create_note derives its own path from title + suggested_folder (no "path"
    # arg exists on this tool) — pass suggested_folder to skip the
    # auto_place_folder Search call and keep the path deterministic.
    assert {:ok, _} =
             Handlers.handle("create_note", user, vault, %{
               "title" => "A via MCP",
               "content" => "body text",
               "suggested_folder" => "mcp"
             })

    assert_receive %Phoenix.Socket.Broadcast{event: "note_changed", payload: p}
    assert p["event_type"] == "upsert"
    assert p["path"] == "mcp/A via MCP.md"
    assert p["content"] =~ "body text"
  end

  test "write_note broadcasts note_changed", %{user: user, vault: vault} do
    assert {:ok, _} =
             Handlers.handle("write_note", user, vault, %{
               "path" => "mcp/b.md",
               "content" => "# B"
             })

    assert_receive %Phoenix.Socket.Broadcast{
      event: "note_changed",
      payload: %{"path" => "mcp/b.md", "event_type" => "upsert"}
    }
  end

  test "append_to_note broadcasts the appended content", %{user: user, vault: vault} do
    {:ok, _} =
      Handlers.handle("create_note", user, vault, %{
        "title" => "C",
        "content" => "body",
        "suggested_folder" => "mcp"
      })

    assert_receive %Phoenix.Socket.Broadcast{event: "note_changed"}

    assert {:ok, _} =
             Handlers.handle("append_to_note", user, vault, %{
               "path" => "mcp/C.md",
               "text" => "tail"
             })

    assert_receive %Phoenix.Socket.Broadcast{event: "note_changed", payload: p}
    assert p["content"] =~ "tail"
  end

  test "patch_note broadcasts the replaced content", %{user: user, vault: vault} do
    {:ok, _} =
      Handlers.handle("write_note", user, vault, %{
        "path" => "mcp/patch.md",
        "content" => "# Patch\n\nfind me here"
      })

    assert_receive %Phoenix.Socket.Broadcast{event: "note_changed"}

    assert {:ok, _} =
             Handlers.handle("patch_note", user, vault, %{
               "path" => "mcp/patch.md",
               "find" => "find me",
               "replace" => "replaced"
             })

    assert_receive %Phoenix.Socket.Broadcast{event: "note_changed", payload: p}
    assert p["content"] =~ "replaced here"
  end

  test "update_section broadcasts the new section content", %{user: user, vault: vault} do
    {:ok, _} =
      Handlers.handle("write_note", user, vault, %{
        "path" => "mcp/section.md",
        "content" => "# Doc\n\n## Notes\n\nold body\n"
      })

    assert_receive %Phoenix.Socket.Broadcast{event: "note_changed"}

    assert {:ok, _} =
             Handlers.handle("update_section", user, vault, %{
               "path" => "mcp/section.md",
               "heading" => "Notes",
               "content" => "new body"
             })

    assert_receive %Phoenix.Socket.Broadcast{event: "note_changed", payload: p}
    assert p["content"] =~ "new body"
    refute p["content"] =~ "old body"
  end

  test "rename_note broadcasts a delete for the old path and an upsert for the new path", %{
    user: user,
    vault: vault
  } do
    {:ok, _} =
      Handlers.handle("create_note", user, vault, %{
        "title" => "Old",
        "content" => "body",
        "suggested_folder" => "mcp"
      })

    assert_receive %Phoenix.Socket.Broadcast{event: "note_changed"}

    assert {:ok, _} =
             Handlers.handle("rename_note", user, vault, %{
               "old_path" => "mcp/Old.md",
               "new_path" => "mcp/New.md"
             })

    # rename_note/4 is not a single event: it broadcasts a "delete" for the
    # old path THEN an "upsert" for the new path (Notes.rename_note, notes.ex
    # ~1160-1162) — there is no distinct "note_renamed" event.
    assert_receive %Phoenix.Socket.Broadcast{
      event: "note_changed",
      payload: %{"event_type" => "delete", "path" => "mcp/Old.md"}
    }

    assert_receive %Phoenix.Socket.Broadcast{
      event: "note_changed",
      payload: %{"event_type" => "upsert", "path" => "mcp/New.md"}
    }
  end

  test "delete_note broadcasts the delete event with the note id", %{user: user, vault: vault} do
    {:ok, _} =
      Handlers.handle("create_note", user, vault, %{
        "title" => "Gone",
        "content" => "body",
        "suggested_folder" => "mcp"
      })

    assert_receive %Phoenix.Socket.Broadcast{event: "note_changed"}
    {:ok, note} = Notes.get_note(user, vault, "mcp/Gone.md")

    assert {:ok, _} = Handlers.handle("delete_note", user, vault, %{"path" => "mcp/Gone.md"})

    assert_receive %Phoenix.Socket.Broadcast{
      event: "note_changed",
      payload: %{"event_type" => "delete", "path" => "mcp/Gone.md", "id" => id}
    }

    assert id == note.id
  end

  test "MCP write advances the sync changes feed", %{user: user, vault: vault} do
    since = ~U[2020-01-01 00:00:00Z]
    {:ok, %{changes: before_changes}} = Notes.list_changes_page(user, vault, since)
    refute Enum.any?(before_changes, &(&1.path == "mcp/feed.md"))

    assert {:ok, _} =
             Handlers.handle("write_note", user, vault, %{
               "path" => "mcp/feed.md",
               "content" => "# Feed"
             })

    assert_receive %Phoenix.Socket.Broadcast{event: "note_changed"}

    {:ok, %{changes: after_changes}} = Notes.list_changes_page(user, vault, since)
    assert Enum.any?(after_changes, &(&1.path == "mcp/feed.md"))
  end
end
