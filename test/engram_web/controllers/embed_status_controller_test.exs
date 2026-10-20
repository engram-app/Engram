defmodule EngramWeb.EmbedStatusControllerTest do
  use EngramWeb.ConnCase, async: true

  describe "GET /api/embed-status" do
    test "returns embedding stats for authenticated user", %{conn: conn} do
      user = insert(:user)
      insert(:vault, user: user, is_default: true)
      {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
      lift_api_rps_cap!(user)
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
      assert resp["keyword_only_too_long"] == 0
    end

    # A note too long for the embed model is searchable by keyword only, and
    # stays so until edited: the client must be able to say so.
    test "counts notes parked keyword-only for an input too long", %{conn: conn} do
      user = insert(:user)
      insert(:vault, user: user, is_default: true)
      {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
      lift_api_rps_cap!(user)
      conn = put_req_header(conn, "authorization", "Bearer #{api_key}")
      park = Engram.Workers.EmbedNote.parked_until_edited()

      insert(:note, user: user, content_hash: "a", embed_hash: "a", embed_retry_after: park)
      # Edited since: no longer the parked content.
      insert(:note, user: user, content_hash: "b", embed_hash: "old", embed_retry_after: park)
      insert(:note, user: user, content_hash: "c", embed_hash: "c")

      resp = get(conn, "/api/embed-status") |> json_response(200)
      assert resp["keyword_only_too_long"] == 1
      assert resp["indexed"] == 2
    end

    test "excludes soft-deleted notes", %{conn: conn} do
      user = insert(:user)
      insert(:vault, user: user, is_default: true)
      {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
      lift_api_rps_cap!(user)
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
