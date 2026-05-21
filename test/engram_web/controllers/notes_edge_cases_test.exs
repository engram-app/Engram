defmodule EngramWeb.NotesEdgeCasesTest do
  @moduledoc """
  Tests for notes edge cases, response shapes, and contract compliance.
  """
  use EngramWeb.ConnCase, async: true

  setup %{conn: conn} do
    user = insert(:user)
    _vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user}
  end

  # ---------------------------------------------------------------------------
  # Edge cases  # ---------------------------------------------------------------------------

  describe "edge cases" do
    test "empty content is accepted", %{conn: conn} do
      conn = post(conn, "/api/notes", %{path: "Test/Empty.md", content: "", mtime: 1_000.0})
      assert %{"note" => note} = json_response(conn, 200)
      assert note["path"] == "Test/Empty.md"
    end

    test "special characters in path", %{conn: conn} do
      conn =
        post(conn, "/api/notes", %{
          path: "Test/Special (Chars) & More!.md",
          content: "# Special",
          mtime: 1_000.0
        })

      assert %{"note" => _} = json_response(conn, 200)
    end

    test "unicode content", %{conn: conn} do
      conn =
        post(conn, "/api/notes", %{
          path: "Test/Unicode.md",
          content: "# Ünïcödé\n\nEmoji test: 🧠 日本語テスト",
          mtime: 1_000.0
        })

      assert %{"note" => _} = json_response(conn, 200)
    end

    test "missing path returns 422", %{conn: conn} do
      conn = post(conn, "/api/notes", %{content: "# Hello", mtime: 1_000.0})
      assert json_response(conn, 422)
    end

    test "path with ? is sanitized", %{conn: conn} do
      conn =
        post(conn, "/api/notes", %{
          path: "Test/Why do I resist feeling good?.md",
          content: "# Why?\n\nGood question.",
          mtime: 1_000.0
        })

      assert %{"note" => note} = json_response(conn, 200)
      assert note["path"] == "Test/Why do I resist feeling good.md"
    end

    test "path with : \" * is sanitized", %{conn: conn} do
      conn =
        post(conn, "/api/notes", %{
          path: "Test/What: A \"Great\" Day*.md",
          content: "# What",
          mtime: 1_000.0
        })

      assert %{"note" => note} = json_response(conn, 200)
      assert note["path"] == "Test/What A Great Day.md"
    end

    test "clean path is preserved", %{conn: conn} do
      conn =
        post(conn, "/api/notes", %{
          path: "2. Knowledge/Sub Folder/Normal Note.md",
          content: "# Normal",
          mtime: 1_000.0
        })

      assert %{"note" => note} = json_response(conn, 200)
      assert note["path"] == "2. Knowledge/Sub Folder/Normal Note.md"
    end

    test "sanitized note is readable by clean path", %{conn: conn} do
      post(conn, "/api/notes", %{
        path: "Test/Why do I resist feeling good?.md",
        content: "# Why?\n\nGood question.",
        mtime: 1_000.0
      })

      conn2 = get(conn, "/api/notes/Test/Why do I resist feeling good.md")
      assert body = json_response(conn2, 200)
      assert body["content"] =~ "Good question"
    end
  end

  # ---------------------------------------------------------------------------
  # Root-level note + title fallback  # ---------------------------------------------------------------------------

  describe "root-level note + title fallback" do
    test "root-level note has empty folder", %{conn: conn} do
      conn =
        post(conn, "/api/notes", %{
          path: "Root Note.md",
          content: "# Root Level\n\nA note at the vault root.",
          mtime: 1_000.0
        })

      assert %{"note" => note} = json_response(conn, 200)
      assert note["folder"] == ""
    end

    test "title falls back to filename when no heading or frontmatter title", %{conn: conn} do
      conn =
        post(conn, "/api/notes", %{
          path: "Test/No Title Note.md",
          content: "Just some content with no heading at all.\n\nSecond paragraph.",
          mtime: 1_000.0
        })

      assert %{"note" => note} = json_response(conn, 200)
      assert note["title"] == "No Title Note"
    end

    test "frontmatter title takes priority over heading", %{conn: conn} do
      conn =
        post(conn, "/api/notes", %{
          path: "Test/Priority.md",
          content: "---\ntitle: Frontmatter Title\n---\n# Heading Title",
          mtime: 1_000.0
        })

      assert %{"note" => note} = json_response(conn, 200)
      assert note["title"] == "Frontmatter Title"
    end

    test "heading title used when no frontmatter title", %{conn: conn} do
      conn =
        post(conn, "/api/notes", %{
          path: "Test/HeadingOnly.md",
          content: "# My Heading\n\nBody text.",
          mtime: 1_000.0
        })

      assert %{"note" => note} = json_response(conn, 200)
      assert note["title"] == "My Heading"
    end
  end

  # ---------------------------------------------------------------------------
  # Tag parsing edge cases  # ---------------------------------------------------------------------------

  describe "tag parsing" do
    test "comma-separated tags in frontmatter", %{conn: conn} do
      conn =
        post(conn, "/api/notes", %{
          path: "Test/Comma Tags.md",
          content: "---\ntags: alpha, beta, gamma\n---\n# Comma Tags",
          mtime: 1_000.0
        })

      assert %{"note" => note} = json_response(conn, 200)
      assert "alpha" in note["tags"]
      assert "beta" in note["tags"]
      assert "gamma" in note["tags"]
    end

    test "YAML inline list tags", %{conn: conn} do
      conn =
        post(conn, "/api/notes", %{
          path: "Test/List Tags.md",
          content: "---\ntags: [health, omega]\n---\n# List Tags",
          mtime: 1_000.0
        })

      assert %{"note" => note} = json_response(conn, 200)
      assert "health" in note["tags"]
      assert "omega" in note["tags"]
    end

    test "no tags returns empty list", %{conn: conn} do
      conn =
        post(conn, "/api/notes", %{
          path: "Test/No Tags.md",
          content: "# No Tags\n\nPlain content.",
          mtime: 1_000.0
        })

      assert %{"note" => note} = json_response(conn, 200)
      assert note["tags"] == []
    end
  end

  # ---------------------------------------------------------------------------
  # Changes response shape  # ---------------------------------------------------------------------------

  describe "changes response shape" do
    test "changes entries have required fields", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/Shape.md", content: "# Shape", mtime: 1_000.0})

      conn2 = get(conn, "/api/notes/changes?since=2020-01-01T00:00:00Z")

      assert %{"changes" => [change | _], "server_time" => server_time} =
               json_response(conn2, 200)

      assert Map.has_key?(change, "path")
      assert Map.has_key?(change, "title")
      assert Map.has_key?(change, "deleted")
      assert Map.has_key?(change, "updated_at")
      assert Map.has_key?(change, "folder")
      assert Map.has_key?(change, "tags")
      assert Map.has_key?(change, "version")
      assert is_binary(server_time)
    end

    test "changes include content field for pull sync", %{conn: conn} do
      post(conn, "/api/notes", %{
        path: "Test/Content.md",
        content: "# Content Check\n\nBody here.",
        mtime: 1_000.0
      })

      conn2 = get(conn, "/api/notes/changes?since=2020-01-01T00:00:00Z")
      assert %{"changes" => changes} = json_response(conn2, 200)
      change = Enum.find(changes, &(&1["path"] == "Test/Content.md"))

      assert Map.has_key?(change, "content"),
             "changes entries must include 'content' field — plugin depends on this for pull sync"

      assert change["content"] =~ "Body here."
    end
  end

  # ---------------------------------------------------------------------------
  # Delete idempotency  # ---------------------------------------------------------------------------

  describe "delete idempotency" do
    test "deleting an already-deleted note returns 200", %{conn: conn} do
      post(conn, "/api/notes", %{
        path: "Test/Double Delete.md",
        content: "# Double",
        mtime: 1_000.0
      })

      delete(conn, "/api/notes/Test/Double Delete.md")

      conn2 = delete(conn, "/api/notes/Test/Double Delete.md")
      assert %{"deleted" => true} = json_response(conn2, 200)
    end

    test "deleting a nonexistent note returns 200", %{conn: conn} do
      conn = delete(conn, "/api/notes/Fake/Note.md")
      assert %{"deleted" => true} = json_response(conn, 200)
    end
  end

  # ---------------------------------------------------------------------------
  # Note read response shape
  # ---------------------------------------------------------------------------

  describe "GET /notes/:path response shape" do
    test "includes all fields the plugin needs", %{conn: conn} do
      post(conn, "/api/notes", %{
        path: "Test/FullShape.md",
        content: "---\ntags: [a, b]\n---\n# Full Shape\n\nBody.",
        mtime: 1_709_234_567.0
      })

      conn2 = get(conn, "/api/notes/Test/FullShape.md")
      body = json_response(conn2, 200)

      assert body["path"] == "Test/FullShape.md"
      assert body["title"] == "Full Shape"
      assert body["folder"] == "Test"
      assert body["tags"] == ["a", "b"]
      assert body["content"] =~ "Body."
      assert is_integer(body["version"]) or is_float(body["version"])
      assert body["updated_at"]
    end
  end
end
