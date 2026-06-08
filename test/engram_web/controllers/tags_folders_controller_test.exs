defmodule EngramWeb.TagsFoldersControllerTest do
  use EngramWeb.ConnCase, async: true

  setup %{conn: conn} do
    user = insert(:user)
    _vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user}
  end

  describe "GET /tags" do
    test "returns unique tags for user", %{conn: conn} do
      post(conn, "/api/notes", %{
        path: "A.md",
        content: "---\ntags: [health, fitness]\n---",
        mtime: 1_000.0
      })

      post(conn, "/api/notes", %{
        path: "B.md",
        content: "---\ntags: [health, nutrition]\n---",
        mtime: 1_000.0
      })

      conn = get(conn, "/api/tags")
      assert %{"tags" => tags} = json_response(conn, 200)
      tag_names = Enum.map(tags, & &1["name"])
      assert "health" in tag_names
      assert "fitness" in tag_names
      assert "nutrition" in tag_names
      assert Enum.count(tag_names, &(&1 == "health")) == 1
    end

    test "returns 401 without auth" do
      conn =
        build_conn()
        |> get("/api/tags")

      assert json_response(conn, 401)
    end
  end

  describe "GET /folders" do
    test "returns unique folders for user", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Folder A/Note.md", content: "x", mtime: 1_000.0})
      post(conn, "/api/notes", %{path: "Folder B/Note.md", content: "x", mtime: 1_000.0})
      post(conn, "/api/notes", %{path: "Folder A/Other.md", content: "x", mtime: 1_000.0})

      conn = get(conn, "/api/folders")
      assert %{"folders" => folders} = json_response(conn, 200)
      folder_names = Enum.map(folders, & &1["name"])
      assert "Folder A" in folder_names
      assert "Folder B" in folder_names
      assert Enum.count(folder_names, &(&1 == "Folder A")) == 1
    end

    test "returns 401 without auth" do
      conn =
        build_conn()
        |> get("/api/folders")

      assert json_response(conn, 401)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /folders/list?folder=
  # ---------------------------------------------------------------------------

  describe "GET /folders/list" do
    test "returns notes in a specific folder", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Work/Alpha.md", content: "# Alpha", mtime: 1_000.0})
      post(conn, "/api/notes", %{path: "Work/Beta.md", content: "# Beta", mtime: 1_000.0})
      post(conn, "/api/notes", %{path: "Personal/Other.md", content: "# Other", mtime: 1_000.0})

      conn2 = get(conn, "/api/folders/list", %{folder: "Work"})
      body = json_response(conn2, 200)

      assert length(body["notes"]) == 2
      paths = Enum.map(body["notes"], & &1["path"])
      assert "Work/Alpha.md" in paths
      assert "Work/Beta.md" in paths
    end

    test "returns root-level notes when folder is empty string", %{conn: conn} do
      post(conn, "/api/notes", %{path: "RootNote.md", content: "# Root", mtime: 1_000.0})
      post(conn, "/api/notes", %{path: "Sub/Nested.md", content: "# Nested", mtime: 1_000.0})

      conn2 = get(conn, "/api/folders/list", %{folder: ""})
      body = json_response(conn2, 200)

      paths = Enum.map(body["notes"], & &1["path"])
      assert "RootNote.md" in paths
      refute "Sub/Nested.md" in paths
    end

    test "returns empty list for nonexistent folder", %{conn: conn} do
      conn = get(conn, "/api/folders/list", %{folder: "Nonexistent"})
      body = json_response(conn, 200)
      assert body["notes"] == []
    end

    test "GET folder-notes list includes id on each note", %{conn: conn} do
      post(conn, "/api/notes", %{path: "src/a.md", content: "# A", mtime: 1_000.0})

      conn2 = get(conn, "/api/folders/list", %{folder: "src"})
      body = json_response(conn2, 200)
      [n | _] = body["notes"]
      assert is_integer(n["id"])
    end
  end

  # ---------------------------------------------------------------------------
  # POST /folders/rename
  # ---------------------------------------------------------------------------

  describe "POST /folders/rename" do
    test "renames folder and all notes in it", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Old/A.md", content: "# A", mtime: 1_000.0})
      post(conn, "/api/notes", %{path: "Old/B.md", content: "# B", mtime: 1_000.0})
      post(conn, "/api/notes", %{path: "Other/C.md", content: "# C", mtime: 1_000.0})

      conn2 =
        post(conn, "/api/folders/rename", %{old_path: "Old", new_path: "New"})

      assert %{"count" => 2, "old_path" => "Old", "new_path" => "New", "renamed" => true} =
               json_response(conn2, 200)

      # Old folder should be empty
      conn3 = get(conn, "/api/folders/list", %{folder: "Old"})
      assert json_response(conn3, 200)["notes"] == []

      # New folder should have the notes
      conn4 = get(conn, "/api/folders/list", %{folder: "New"})
      paths = Enum.map(json_response(conn4, 200)["notes"], & &1["path"])
      assert "New/A.md" in paths
      assert "New/B.md" in paths
    end

    test "renames nested subfolders", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Parent/Child/Note.md", content: "# Deep", mtime: 1_000.0})

      post(conn, "/api/folders/rename", %{old_path: "Parent", new_path: "Renamed"})

      conn2 = get(conn, "/api/notes/Renamed/Child/Note.md")
      assert json_response(conn2, 200)["content"] =~ "Deep"
    end

    test "returns 404 for nonexistent folder", %{conn: conn} do
      conn = post(conn, "/api/folders/rename", %{old_path: "Ghost", new_path: "New"})
      assert json_response(conn, 404)
    end

    test "returns 409 when target folder has notes", %{conn: conn} do
      post(conn, "/api/notes", %{path: "src/a.md", content: "# A", mtime: 1_000.0})
      post(conn, "/api/notes", %{path: "dst/b.md", content: "# B", mtime: 1_000.0})

      conn2 = post(conn, "/api/folders/rename", %{old_path: "src", new_path: "dst"})
      assert json_response(conn2, 409) == %{"error" => "conflict"}

      # Source folder still intact
      conn3 = get(conn, "/api/folders/list", %{folder: "src"})
      paths = Enum.map(json_response(conn3, 200)["notes"], & &1["path"])
      assert "src/a.md" in paths
    end
  end
end
