defmodule EngramWeb.EmbedStatusControllerTest do
  use EngramWeb.ConnCase, async: true

  describe "GET /api/embed-status" do
    test "returns embedding stats for authenticated user", %{conn: conn} do
      user = insert(:user)
      insert(:vault, user: user, is_default: true)
      {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
      grant_api_write!(user)
      conn = put_req_header(conn, "authorization", "Bearer #{api_key}")

      # 2 indexed, 1 pending (nil), 1 stale
      insert(:note, user: user, content_hash: "aaa", embed_hash: "aaa")
      insert(:note, user: user, content_hash: "bbb", embed_hash: "bbb")
      insert(:note, user: user, content_hash: "ccc", embed_hash: nil)
      insert(:note, user: user, content_hash: "ddd", embed_hash: "old")

      resp = get(conn, "/api/embed-status") |> json_response(200)

      assert resp["total"] == 4
      assert resp["indexed"] == 2
      assert resp["pending"] == 2
    end

    test "excludes soft-deleted notes", %{conn: conn} do
      user = insert(:user)
      insert(:vault, user: user, is_default: true)
      {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
      grant_api_write!(user)
      conn = put_req_header(conn, "authorization", "Bearer #{api_key}")

      insert(:note, user: user, content_hash: "aaa", embed_hash: "aaa")

      insert(:note,
        user: user,
        content_hash: "bbb",
        embed_hash: nil,
        deleted_at: DateTime.utc_now()
      )

      resp = get(conn, "/api/embed-status") |> json_response(200)

      assert resp["total"] == 1
      assert resp["indexed"] == 1
      assert resp["pending"] == 0
    end

    test "returns 401 without auth", %{conn: conn} do
      conn = get(conn, "/api/embed-status")
      assert json_response(conn, 401)
    end
  end
end
