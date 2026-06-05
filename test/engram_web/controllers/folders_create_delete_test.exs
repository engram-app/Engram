defmodule EngramWeb.FoldersCreateDeleteTest do
  use EngramWeb.ConnCase, async: true

  setup %{conn: conn} do
    user = insert(:user)
    _vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user}
  end

  describe "POST /folders" do
    test "creates a marker and returns 201", %{conn: conn} do
      conn = post(conn, "/api/folders", %{"folder" => "Projects/Active"})
      body = json_response(conn, 201)
      assert body["folder"]["name"] == "Projects/Active"
      assert body["folder"]["count"] == 0
    end

    test "idempotent on existing marker", %{conn: conn} do
      _ = post(conn, "/api/folders", %{"folder" => "Twice"})
      conn = post(conn, "/api/folders", %{"folder" => "Twice"})
      assert conn.status in [200, 201]
    end

    test "rejects empty folder with 422", %{conn: conn} do
      conn = post(conn, "/api/folders", %{"folder" => ""})
      body = json_response(conn, 422)
      assert body["error"] =~ "folder"
    end

    test "requires authentication" do
      conn = build_conn() |> post("/api/folders", %{"folder" => "X"})
      assert response(conn, 401)
    end
  end
end
