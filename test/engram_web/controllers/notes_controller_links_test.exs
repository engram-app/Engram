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

  describe "GET /api/attachments/by-id/:id/backlinks" do
    test "returns the notes that embed the attachment", %{conn: conn, user: user, vault: vault} do
      att = Engram.Fixtures.insert_attachment!(user, vault, %{path: "files/a.zip"})

      {:ok, source} =
        Engram.Notes.upsert_note(user, vault, %{path: "S.md", content: "![[a.zip]]", mtime: 1.0},
          actor: "api"
        )

      :ok = perform_job(ExtractNoteLinks, %{note_id: source.id, user_id: user.id})

      body = conn |> get(~p"/api/attachments/by-id/#{att.id}/backlinks") |> json_response(200)
      assert [%{"source_note_id" => sid, "source_path" => "S.md"}] = body["backlinks"]
      assert sid == source.id
    end

    test "400 on a malformed id", %{conn: conn} do
      assert conn |> get(~p"/api/attachments/by-id/nope/backlinks") |> json_response(400)
    end

    # Another user's attachment, linked from that user's note.
    defp foreign_linked_attachment do
      other_user = insert(:user)
      other_vault = insert(:vault, user: other_user, is_default: true)
      att = Engram.Fixtures.insert_attachment!(other_user, other_vault, %{path: "a.zip"})

      {:ok, source} =
        Engram.Notes.upsert_note(
          other_user,
          other_vault,
          %{path: "S.md", content: "![[a.zip]]", mtime: 1.0},
          actor: "api"
        )

      :ok = perform_job(ExtractNoteLinks, %{note_id: source.id, user_id: other_user.id})

      # Control: the edge exists for its owner, so an empty answer for anyone
      # else is the scoping at work, not a missing link.
      assert [_] = Engram.Links.backlinks_for_attachment(other_user, other_vault.id, att.id)
      att
    end

    test "another user's attachment id yields no backlinks (isolation)", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      # The requester holds a key too, so this is the scoping, not the no-key path.
      {:ok, _} =
        Engram.Notes.upsert_note(user, vault, %{path: "Mine.md", content: "x"}, actor: "api")

      att = foreign_linked_attachment()

      body = conn |> get(~p"/api/attachments/by-id/#{att.id}/backlinks") |> json_response(200)
      assert body["backlinks"] == []
    end

    test "a user who has stored nothing yet gets an empty list, not a 500", %{conn: conn} do
      att = foreign_linked_attachment()

      body = conn |> get(~p"/api/attachments/by-id/#{att.id}/backlinks") |> json_response(200)
      assert body["backlinks"] == []
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
