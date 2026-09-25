defmodule EngramWeb.NotesControllerLinksTest do
  # async: false — both describe blocks below call
  # Application.put_env(:engram, :qdrant_url, ...) in setup, which mutates
  # global Application env. Under async: true, concurrent readers in other
  # test modules could observe the temporary value mid-test. See
  # docs/context/exunit-application-env-races.md.
  use EngramWeb.ConnCase, async: false

  import Mox

  setup :authed_api_conn

  # ---------------------------------------------------------------------------
  # links / backlinks (Task 9)
  # ---------------------------------------------------------------------------

  describe "GET /api/notes/by-id/:id — links" do
    setup :verify_on_exit!

    setup do
      bypass = Bypass.open()
      Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
      on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)
      %{bypass: bypass}
    end

    test "returns resolved links after indexing", %{
      conn: conn,
      user: user,
      vault: vault,
      bypass: bypass
    } do
      {:ok, target} =
        Engram.Notes.upsert_note(user, vault, %{path: "B.md", content: "# B", mtime: 1_000.0})

      {:ok, source} =
        Engram.Notes.upsert_note(user, vault, %{
          path: "Source.md",
          content: "[[B]]",
          mtime: 1_000.0
        })

      expect_embed_and_upsert(bypass)
      assert {:ok, _} = Engram.Indexing.index_note(source, vault)

      conn = get(conn, ~p"/api/notes/by-id/#{source.id}")
      body = json_response(conn, 200)

      assert [link] = body["links"]
      assert link["target_text"] == "B"
      assert link["target_note_id"] == target.id
      assert link["dangling"] == false
    end
  end

  describe "GET /api/notes/by-id/:id/backlinks" do
    setup :verify_on_exit!

    setup do
      bypass = Bypass.open()
      Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
      on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)
      %{bypass: bypass}
    end

    test "returns the inverse edges with source path/title", %{
      conn: conn,
      user: user,
      vault: vault,
      bypass: bypass
    } do
      {:ok, target} =
        Engram.Notes.upsert_note(user, vault, %{path: "B.md", content: "# B", mtime: 1_000.0})

      {:ok, source} =
        Engram.Notes.upsert_note(user, vault, %{
          path: "Source.md",
          content: "[[B]]",
          mtime: 1_000.0
        })

      expect_embed_and_upsert(bypass)
      assert {:ok, _} = Engram.Indexing.index_note(source, vault)

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
        Engram.Notes.upsert_note(other_user, other_vault, %{path: "a.md", content: "# A"})

      conn = get(conn, ~p"/api/notes/by-id/#{other_note.id}/backlinks")
      assert json_response(conn, 404) == %{"error" => "not found"}
    end

    test "returns 400 for non-uuid id", %{conn: conn} do
      conn = get(conn, ~p"/api/notes/by-id/abc/backlinks")
      assert json_response(conn, 400) == %{"error" => "invalid id"}
    end
  end

  # Shared by the links/backlinks describes: mocks the embedder + Qdrant
  # upsert call so `Indexing.index_note/2` can run synchronously in-test.
  defp expect_embed_and_upsert(bypass) do
    Engram.MockEmbedder
    |> expect(:embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    Bypass.expect(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)
  end
end
