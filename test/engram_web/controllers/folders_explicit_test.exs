defmodule EngramWeb.FoldersExplicitTest do
  use EngramWeb.ConnCase, async: true

  setup :authed_api_conn

  describe "GET /folders/explicit" do
    test "returns only marker rows, not derived folders", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      {:ok, _} = Engram.Notes.create_folder_marker(user, vault, "Explicit")

      {:ok, _} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "Derived/a.md",
          "content" => "a",
          "mtime" => 1.0
        })

      conn = get(conn, ~p"/api/folders/explicit")
      body = json_response(conn, 200)
      names = Enum.map(body["folders"], & &1["name"])

      assert "Explicit" in names
      refute "Derived" in names
    end

    test "returns empty list when user has no markers", %{conn: conn} do
      conn = get(conn, ~p"/api/folders/explicit")
      body = json_response(conn, 200)
      assert body["folders"] == []
    end

    test "requires authentication" do
      conn = build_conn() |> get(~p"/api/folders/explicit")
      assert response(conn, 401)
    end
  end
end
