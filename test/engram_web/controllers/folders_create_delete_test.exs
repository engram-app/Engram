defmodule EngramWeb.FoldersCreateDeleteTest do
  use EngramWeb.ConnCase, async: true

  setup %{conn: conn} do
    user = insert(:user)
    vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user, vault: vault}
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

    test "broadcasts folders.batch create on the sync channel", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
      post(conn, "/api/folders", %{"folder" => "Live/New"})

      assert_receive %Phoenix.Socket.Broadcast{
        event: "folders.batch",
        payload: %{op: "create", folder: "Live/New"}
      }
    end

    test "broadcasts folders.batch create on idempotent re-create too", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      _ = post(conn, "/api/folders", %{"folder" => "Twice"})
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
      post(conn, "/api/folders", %{"folder" => "Twice"})

      assert_receive %Phoenix.Socket.Broadcast{
        event: "folders.batch",
        payload: %{op: "create", folder: "Twice"}
      }
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

  describe "DELETE /folders/*path" do
    test "returns 204 after deleting an existing marker", %{conn: conn} do
      _ = post(conn, ~p"/api/folders", %{"folder" => "Doomed"})
      conn = delete(conn, ~p"/api/folders/Doomed")
      assert response(conn, 204)
    end

    test "returns 204 when no marker exists (idempotent)", %{conn: conn} do
      conn = delete(conn, ~p"/api/folders/Ghost")
      assert response(conn, 204)
    end

    test "URI-encoded segments are decoded", %{conn: conn} do
      _ = post(conn, ~p"/api/folders", %{"folder" => "Has Space/Sub"})
      conn = delete(conn, "/api/folders/Has%20Space/Sub")
      assert response(conn, 204)
    end
  end
end
