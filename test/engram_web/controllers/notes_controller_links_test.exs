defmodule EngramWeb.NotesControllerLinksTest do
  use EngramWeb.ConnCase, async: true
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Workers.ExtractNoteLinks

  setup :authed_api_conn

  # ---------------------------------------------------------------------------
  # links / backlinks (Task 9)
  # ---------------------------------------------------------------------------

  describe "GET /api/notes/by-id/:id — links" do
    test "returns resolved links after extraction", %{conn: conn, user: user, vault: vault} do
      {:ok, target} =
        Engram.Notes.upsert_note(user, vault, %{path: "B.md", content: "# B", mtime: 1_000.0},
          actor: "api"
        )

      {:ok, source} =
        Engram.Notes.upsert_note(
          user,
          vault,
          %{
            path: "Source.md",
            content: "[[B]]",
            mtime: 1_000.0
          },
          actor: "api"
        )

      :ok = perform_job(ExtractNoteLinks, %{note_id: source.id, user_id: user.id})

      conn = get(conn, ~p"/api/notes/by-id/#{source.id}")
      body = json_response(conn, 200)

      assert [link] = body["links"]
      assert link["target_text"] == "B"
      assert link["target_note_id"] == target.id
      assert link["dangling"] == false
    end
  end

  describe "GET /api/notes/by-id/:id/backlinks" do
    test "returns the inverse edges with source path/title", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      {:ok, target} =
        Engram.Notes.upsert_note(user, vault, %{path: "B.md", content: "# B", mtime: 1_000.0},
          actor: "api"
        )

      {:ok, source} =
        Engram.Notes.upsert_note(
          user,
          vault,
          %{
            path: "Source.md",
            content: "[[B]]",
            mtime: 1_000.0
          },
          actor: "api"
        )

      :ok = perform_job(ExtractNoteLinks, %{note_id: source.id, user_id: user.id})

      conn = get(conn, ~p"/api/notes/by-id/#{target.id}/backlinks")
      body = json_response(conn, 200)

      assert [backlink] = body["backlinks"]
      assert backlink["source_note_id"] == source.id
      assert backlink["source_path"] == "Source.md"
      assert backlink["source_title"] == "Source"
    end

    test "returns 404 for another user's note (isolation)", %{conn: conn} do
      other_user = insert(:user)
      other_vault = insert(:vault, user: other_user, is_default: true)

      {:ok, other_note} =
        Engram.Notes.upsert_note(other_user, other_vault, %{path: "a.md", content: "# A"},
          actor: "api"
        )

      conn = get(conn, ~p"/api/notes/by-id/#{other_note.id}/backlinks")
      assert json_response(conn, 404) == %{"error" => "not found"}
    end

    test "returns 400 for non-uuid id", %{conn: conn} do
      conn = get(conn, ~p"/api/notes/by-id/abc/backlinks")
      assert json_response(conn, 400) == %{"error" => "invalid id"}
    end
  end
end
