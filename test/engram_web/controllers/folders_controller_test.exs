defmodule EngramWeb.FoldersControllerTest do
  use EngramWeb.ConnCase, async: true

  setup :authed_api_conn

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
