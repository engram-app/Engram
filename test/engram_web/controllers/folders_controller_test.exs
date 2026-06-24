defmodule EngramWeb.FoldersControllerTest do
  use EngramWeb.ConnCase, async: true

  setup :authed_api_conn

  describe "POST /api/folders/rename" do
    test "rename cascades to attachments", %{conn: conn, user: user, vault: vault} do
      {:ok, _att} =
        Engram.Attachments.upsert_attachment(user, vault, %{
          "path" => "Docs/a.txt",
          "content_base64" => Base.encode64("hello")
        })

      conn
      |> post(~p"/api/folders/rename", %{"old_path" => "Docs", "new_path" => "Archive"})
      |> json_response(200)

      {:ok, metas} = Engram.Attachments.list_attachments(user, vault)
      assert Enum.map(metas, & &1.path) == ["Archive/a.txt"]
    end
  end

  describe "GET /api/folders" do
    test "response includes id and parent_id per folder marker", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      {:ok, _parent} = Engram.Notes.create_folder_marker(user, vault, "Projects")
      {:ok, _child} = Engram.Notes.create_folder_marker(user, vault, "Projects/Engram")

      body = conn |> get(~p"/api/folders") |> json_response(200)

      parent = Enum.find(body["folders"], &(&1["name"] == "Projects"))
      child = Enum.find(body["folders"], &(&1["name"] == "Projects/Engram"))

      assert is_binary(parent["id"])
      assert parent["parent_id"] == nil
      assert is_binary(child["id"])
      assert child["parent_id"] == parent["id"]
    end
  end

  describe "GET /api/folders/by-id/:id/notes" do
    test "returns notes inside the folder", %{conn: conn, user: user, vault: vault} do
      {:ok, marker} = Engram.Notes.create_folder_marker(user, vault, "Projects")

      {:ok, _} =
        Engram.Notes.upsert_note(user, vault, %{path: "Projects/a.md", content: "# A"})

      body = conn |> get(~p"/api/folders/by-id/#{marker.id}/notes") |> json_response(200)

      assert [%{"path" => "Projects/a.md", "id" => _}] = body["notes"]
    end

    test "404 when marker doesn't belong to caller's vault", %{conn: conn} do
      conn |> get(~p"/api/folders/by-id/#{Ecto.UUID.generate()}/notes") |> json_response(404)
    end
  end
end
