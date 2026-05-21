defmodule EngramWeb.MultiTenantTest do
  @moduledoc """
  Multi-tenant isolation tests — verifies that users cannot access each other's data.
  """
  use EngramWeb.ConnCase, async: true

  setup %{conn: conn} do
    user1 = insert(:user)
    user2 = insert(:user)
    insert(:vault, user: user1, is_default: true)
    insert(:vault, user: user2, is_default: true)
    {:ok, key1, _} = Engram.Accounts.create_api_key(user1, "user1-key")
    grant_api_write!(user1)
    {:ok, key2, _} = Engram.Accounts.create_api_key(user2, "user2-key")
    grant_api_write!(user2)

    conn1 = put_req_header(conn, "authorization", "Bearer #{key1}")
    conn2 = put_req_header(conn, "authorization", "Bearer #{key2}")

    # Seed user1 with notes
    post(conn1, "/api/notes", %{
      path: "Folder A/Private.md",
      content: "---\ntags: [secret, private]\n---\n# User 1 Private",
      mtime: 1_000.0
    })

    post(conn1, "/api/notes", %{
      path: "Folder B/Also Private.md",
      content: "---\ntags: [secret]\n---\n# Also Private",
      mtime: 1_000.0
    })

    %{conn1: conn1, conn2: conn2, user1: user1, user2: user2}
  end

  # ---------------------------------------------------------------------------
  # Note read isolation
  # ---------------------------------------------------------------------------

  describe "note read isolation" do
    test "user2 cannot read user1's note", %{conn2: conn2} do
      conn = get(conn2, "/api/notes/Folder A/Private.md")
      assert json_response(conn, 404)
    end

    test "user1 can read own note", %{conn1: conn1} do
      conn = get(conn1, "/api/notes/Folder A/Private.md")
      assert %{"path" => "Folder A/Private.md"} = json_response(conn, 200)
    end
  end

  # ---------------------------------------------------------------------------
  # Folder isolation
  # ---------------------------------------------------------------------------

  describe "folder isolation" do
    test "user2 sees no folders", %{conn2: conn2} do
      conn = get(conn2, "/api/folders")
      assert %{"folders" => folders} = json_response(conn, 200)
      assert folders == []
    end

    test "user1 sees own folders", %{conn1: conn1} do
      conn = get(conn1, "/api/folders")
      assert %{"folders" => folders} = json_response(conn, 200)
      folder_names = Enum.map(folders, & &1["name"])
      assert "Folder A" in folder_names
      assert "Folder B" in folder_names
    end
  end

  # ---------------------------------------------------------------------------
  # Tag isolation
  # ---------------------------------------------------------------------------

  describe "tag isolation" do
    test "user2 sees no tags", %{conn2: conn2} do
      conn = get(conn2, "/api/tags")
      assert %{"tags" => tags} = json_response(conn, 200)
      assert tags == []
    end

    test "user1 sees own tags", %{conn1: conn1} do
      conn = get(conn1, "/api/tags")
      assert %{"tags" => tags} = json_response(conn, 200)
      tag_names = Enum.map(tags, & &1["name"])
      assert "secret" in tag_names
      assert "private" in tag_names
    end
  end

  # ---------------------------------------------------------------------------
  # Changes isolation
  # ---------------------------------------------------------------------------

  describe "changes isolation" do
    test "user2 sees no changes", %{conn2: conn2} do
      conn = get(conn2, "/api/notes/changes?since=2020-01-01T00:00:00Z")
      assert %{"changes" => changes} = json_response(conn, 200)
      assert changes == []
    end

    test "user1 sees own changes", %{conn1: conn1} do
      conn = get(conn1, "/api/notes/changes?since=2020-01-01T00:00:00Z")
      assert %{"changes" => changes} = json_response(conn, 200)
      assert length(changes) >= 2
    end
  end

  # ---------------------------------------------------------------------------
  # Write isolation
  # ---------------------------------------------------------------------------

  describe "write isolation" do
    test "user2 cannot delete user1's note", %{conn1: conn1, conn2: conn2} do
      # User2 tries to delete user1's note (should be no-op since it's not visible)
      delete(conn2, "/api/notes/Folder A/Private.md")

      # User1's note should still be there
      conn = get(conn1, "/api/notes/Folder A/Private.md")
      assert json_response(conn, 200)
    end

    test "user2's note at same path doesn't conflict with user1", %{conn1: conn1, conn2: conn2} do
      # User2 creates a note with the same path
      post(conn2, "/api/notes", %{
        path: "Folder A/Private.md",
        content: "# User 2's version",
        mtime: 2_000.0
      })

      # User1 still sees their own content
      conn = get(conn1, "/api/notes/Folder A/Private.md")
      body = json_response(conn, 200)
      assert body["content"] =~ "User 1 Private"

      # User2 sees their own content
      conn2_read = get(conn2, "/api/notes/Folder A/Private.md")
      body2 = json_response(conn2_read, 200)
      assert body2["content"] =~ "User 2's version"
    end
  end
end
