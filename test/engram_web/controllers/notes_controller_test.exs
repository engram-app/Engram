defmodule EngramWeb.NotesControllerTest do
  use EngramWeb.ConnCase, async: true

  setup %{conn: conn} do
    user = insert(:user)
    _vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user}
  end

  # ---------------------------------------------------------------------------
  # POST /notes
  # ---------------------------------------------------------------------------

  describe "POST /notes" do
    test "creates a note and returns metadata", %{conn: conn} do
      conn =
        post(conn, "/api/notes", %{
          path: "Test/Hello World.md",
          content: "---\ntags: [health, omega]\n---\n# Hello World\n\nBody.",
          mtime: 1_709_234_567.0
        })

      assert %{"note" => note} = json_response(conn, 200)
      assert note["path"] == "Test/Hello World.md"
      assert note["title"] == "Hello World"
      assert note["folder"] == "Test"
      assert note["tags"] == ["health", "omega"]
      assert note["version"] == 1
    end

    test "upserts an existing note and increments version", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/File.md", content: "# v1", mtime: 1_000.0})

      conn2 = post(conn, "/api/notes", %{path: "Test/File.md", content: "# v2", mtime: 2_000.0})

      assert %{"note" => note} = json_response(conn2, 200)
      assert note["version"] == 2
    end

    test "sanitizes illegal chars in path", %{conn: conn} do
      conn =
        post(conn, "/api/notes", %{
          path: "Test/Why do I resist?.md",
          content: "# Why",
          mtime: 1_000.0
        })

      assert %{"note" => note} = json_response(conn, 200)
      assert note["path"] == "Test/Why do I resist.md"
    end

    test "returns 422 when path is missing", %{conn: conn} do
      conn = post(conn, "/api/notes", %{content: "# Hello", mtime: 1_000.0})
      assert json_response(conn, 422)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> post("/api/notes", %{path: "Test/A.md", content: "x", mtime: 1_000.0})

      assert json_response(conn, 401)
    end
  end

  # ---------------------------------------------------------------------------
  # Version conflict (409)
  # ---------------------------------------------------------------------------

  describe "POST /notes version conflict" do
    test "returns 409 when client version doesn't match server version", %{conn: conn} do
      # Create note (version 1)
      post(conn, "/api/notes", %{path: "Test/Conflict.md", content: "# v1", mtime: 1_000.0})

      # Update note (version 2)
      post(conn, "/api/notes", %{path: "Test/Conflict.md", content: "# v2", mtime: 2_000.0})

      # Client still thinks it's version 1 — should get 409
      conn2 =
        post(conn, "/api/notes", %{
          path: "Test/Conflict.md",
          content: "# v1-modified",
          mtime: 3_000.0,
          version: 1
        })

      assert %{"conflict" => true, "server_note" => server_note} =
               json_response(conn2, 409)

      assert server_note["path"] == "Test/Conflict.md"
      assert server_note["version"] == 2
      assert server_note["content"] == "# v2"
    end

    test "succeeds when client version matches server version", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/Match.md", content: "# v1", mtime: 1_000.0})

      conn2 =
        post(conn, "/api/notes", %{
          path: "Test/Match.md",
          content: "# v2",
          mtime: 2_000.0,
          version: 1
        })

      assert %{"note" => note} = json_response(conn2, 200)
      assert note["version"] == 2
    end

    test "ignores version check on new note creation", %{conn: conn} do
      conn =
        post(conn, "/api/notes", %{
          path: "Test/New.md",
          content: "# New",
          mtime: 1_000.0,
          version: 1
        })

      assert %{"note" => note} = json_response(conn, 200)
      assert note["version"] == 1
    end

    test "allows upsert without version param (backwards compatible)", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/NoVer.md", content: "# v1", mtime: 1_000.0})

      conn2 = post(conn, "/api/notes", %{path: "Test/NoVer.md", content: "# v2", mtime: 2_000.0})
      assert %{"note" => note} = json_response(conn2, 200)
      assert note["version"] == 2
    end
  end

  # ---------------------------------------------------------------------------
  # POST /notes/append
  # ---------------------------------------------------------------------------

  describe "POST /notes/append" do
    test "appends text to an existing note", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/Append.md", content: "# Hello", mtime: 1_000.0})

      conn2 = post(conn, "/api/notes/append", %{path: "Test/Append.md", text: "\nWorld!"})
      assert %{"note" => note} = json_response(conn2, 200)
      assert note["content"] =~ "# Hello"
      assert note["content"] =~ "World!"
    end

    test "creates new note when note doesn't exist", %{conn: conn} do
      conn = post(conn, "/api/notes/append", %{path: "Nope/Missing.md", text: "stuff"})
      resp = json_response(conn, 200)
      assert resp["created"] == true
      assert resp["path"] == "Nope/Missing.md"
      assert resp["note"]["content"] =~ "stuff"
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> post("/api/notes/append", %{path: "a.md", text: "x"})

      assert json_response(conn, 401)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /notes/:path
  # ---------------------------------------------------------------------------

  describe "GET /notes/:path" do
    test "returns note by path", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/Readable.md", content: "# Readable", mtime: 1_000.0})

      conn = get(conn, "/api/notes/Test/Readable.md")
      assert body = json_response(conn, 200)
      assert body["path"] == "Test/Readable.md"
    end

    test "returns 404 for missing note", %{conn: conn} do
      conn = get(conn, "/api/notes/Nope/Missing.md")
      assert json_response(conn, 404)
    end

    test "returns 404 for deleted note", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/Gone.md", content: "# Gone", mtime: 1_000.0})
      delete(conn, "/api/notes/Test/Gone.md")

      conn = get(conn, "/api/notes/Test/Gone.md")
      assert json_response(conn, 404)
    end

    test "user cannot read another user's note", %{conn: conn} do
      other_user = insert(:user)
      # Insert directly via factory to avoid with_tenant role-switch leaking into sandbox
      insert(:note, user: other_user, path: "Test/Private.md", folder: "Test")

      conn = get(conn, "/api/notes/Test/Private.md")
      assert json_response(conn, 404)
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE /notes/:path
  # ---------------------------------------------------------------------------

  describe "DELETE /notes/:path" do
    test "soft-deletes a note", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/Bye.md", content: "# Bye", mtime: 1_000.0})

      conn = delete(conn, "/api/notes/Test/Bye.md")
      assert %{"deleted" => true} = json_response(conn, 200)
    end

    test "is idempotent for nonexistent note", %{conn: conn} do
      conn = delete(conn, "/api/notes/Fake/Note.md")
      assert %{"deleted" => true} = json_response(conn, 200)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /notes/changes
  # ---------------------------------------------------------------------------

  describe "GET /notes/changes" do
    test "returns changes since timestamp", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/Recent.md", content: "# Recent", mtime: 1_000.0})

      conn = get(conn, "/api/notes/changes?since=2020-01-01T00:00:00Z")
      assert %{"changes" => changes} = json_response(conn, 200)
      assert Enum.any?(changes, &(&1["path"] == "Test/Recent.md"))
    end

    test "includes deleted notes with deleted=true flag", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/Deleted.md", content: "# Del", mtime: 1_000.0})
      delete(conn, "/api/notes/Test/Deleted.md")

      conn = get(conn, "/api/notes/changes?since=2020-01-01T00:00:00Z")
      assert %{"changes" => changes} = json_response(conn, 200)

      deleted = Enum.find(changes, &(&1["path"] == "Test/Deleted.md"))
      assert deleted["deleted"] == true
    end

    test "returns empty list for future timestamp", %{conn: conn} do
      conn = get(conn, "/api/notes/changes?since=2099-01-01T00:00:00Z")
      assert %{"changes" => []} = json_response(conn, 200)
    end

    test "returns 400 for invalid timestamp", %{conn: conn} do
      conn = get(conn, "/api/notes/changes?since=not-a-date")
      assert json_response(conn, 400)
    end

    test "returns 400 when since param is missing", %{conn: conn} do
      conn = get(conn, "/api/notes/changes")
      assert json_response(conn, 400)
    end
  end

  # Pricing v2 §G — server-side notes_cap enforcement
  describe "POST /notes — notes_cap enforcement (pricing v2 §G)" do
    test "returns 402 when user is at notes_cap", %{conn: conn, user: user} do
      # Lower the cap so the test doesn't need to insert 10k notes
      insert(:user_limit_override, user: user, key: "notes_cap", value: %{"v" => 2})

      post(conn, "/api/notes", %{path: "A.md", content: "# A", mtime: 1.0})
      post(conn, "/api/notes", %{path: "B.md", content: "# B", mtime: 2.0})

      conn3 = post(conn, "/api/notes", %{path: "C.md", content: "# C", mtime: 3.0})

      assert %{"error" => "notes_cap_reached", "upgrade_required" => true} =
               json_response(conn3, 402)
    end

    test "permits updates to existing notes after cap is hit", %{conn: conn, user: user} do
      insert(:user_limit_override, user: user, key: "notes_cap", value: %{"v" => 1})

      post(conn, "/api/notes", %{path: "A.md", content: "# A v1", mtime: 1.0})

      # Updating A is fine — only NEW notes are gated
      conn2 = post(conn, "/api/notes", %{path: "A.md", content: "# A v2", mtime: 2.0})
      assert %{"note" => _} = json_response(conn2, 200)
    end
  end
end
