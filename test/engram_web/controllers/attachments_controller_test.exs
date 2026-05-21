defmodule EngramWeb.AttachmentsControllerTest do
  # async: false because AttachmentsTest (also async: false) mutates the
  # global :storage adapter via Application.put_env. ExUnit runs async: true
  # cases first, then async: false serially — making this file async: false
  # serializes it against AttachmentsTest and prevents adapter races where
  # a POST/GET pair straddles a flip to MockStorage or Storage.Database.
  use EngramWeb.ConnCase, async: false

  @sample_content "Hello, binary world!"
  @sample_base64 Base.encode64("Hello, binary world!")
  @updated_content "Updated content!"
  @updated_base64 Base.encode64("Updated content!")

  setup %{conn: conn} do
    user = insert(:user)
    _vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user}
  end

  # ---------------------------------------------------------------------------
  # POST /attachments — Upload / Upsert
  # ---------------------------------------------------------------------------

  describe "POST /attachments" do
    test "uploads an attachment and returns metadata", %{conn: conn} do
      conn =
        post(conn, "/api/attachments", %{
          path: "photos/test.png",
          content_base64: @sample_base64,
          mtime: 1_709_234_567.0
        })

      assert %{"attachment" => att} = json_response(conn, 200)
      assert att["path"] == "photos/test.png"
      assert att["mime_type"] == "image/png"
      assert att["size_bytes"] == byte_size(@sample_content)
      assert is_integer(att["id"])
      assert is_binary(att["updated_at"])
    end

    test "auto-detects MIME type from extension", %{conn: conn} do
      conn =
        post(conn, "/api/attachments", %{
          path: "docs/readme.pdf",
          content_base64: @sample_base64,
          mtime: 1_000.0
        })

      assert %{"attachment" => att} = json_response(conn, 200)
      assert att["mime_type"] == "application/pdf"
    end

    test "rejects unknown extension with 415 (defaults to non-allowlisted octet-stream)", %{
      conn: conn
    } do
      conn =
        post(conn, "/api/attachments", %{
          path: "files/data.xyz",
          content_base64: @sample_base64,
          mtime: 1_000.0
        })

      assert json_response(conn, 415) == %{
               "error" => "mime_not_allowed",
               "mime_type" => "application/octet-stream"
             }
    end

    test "rejects .exe extension even with whitelisted MIME claim (belt-and-braces)", %{
      conn: conn
    } do
      conn =
        post(conn, "/api/attachments", %{
          path: "tools/trojan.exe",
          content_base64: @sample_base64,
          mime_type: "image/png",
          mtime: 1_000.0
        })

      assert json_response(conn, 415) == %{
               "error" => "extension_not_allowed",
               "extension" => ".exe"
             }
    end

    test "rejects application/x-msdownload MIME", %{conn: conn} do
      conn =
        post(conn, "/api/attachments", %{
          path: "tools/installer",
          content_base64: @sample_base64,
          mime_type: "application/x-msdownload",
          mtime: 1_000.0
        })

      assert %{"error" => "mime_not_allowed"} = json_response(conn, 415)
    end

    test "allows explicit MIME type override", %{conn: conn} do
      conn =
        post(conn, "/api/attachments", %{
          path: "files/custom.bin",
          content_base64: @sample_base64,
          mime_type: "text/plain",
          mtime: 1_000.0
        })

      assert %{"attachment" => att} = json_response(conn, 200)
      assert att["mime_type"] == "text/plain"
    end

    test "upserts — replaces content on same path", %{conn: conn} do
      post(conn, "/api/attachments", %{
        path: "photos/upsert.png",
        content_base64: @sample_base64,
        mtime: 1_000.0
      })

      conn2 =
        post(conn, "/api/attachments", %{
          path: "photos/upsert.png",
          content_base64: @updated_base64,
          mtime: 2_000.0
        })

      assert %{"attachment" => att} = json_response(conn2, 200)
      assert att["size_bytes"] == byte_size(@updated_content)
    end

    test "undeletes a previously soft-deleted attachment", %{conn: conn} do
      post(conn, "/api/attachments", %{
        path: "photos/revive.png",
        content_base64: @sample_base64,
        mtime: 1_000.0
      })

      delete(conn, "/api/attachments/photos/revive.png")

      # Re-upload should undelete
      conn3 =
        post(conn, "/api/attachments", %{
          path: "photos/revive.png",
          content_base64: @updated_base64,
          mtime: 3_000.0
        })

      assert %{"attachment" => _} = json_response(conn3, 200)

      # Should be readable again
      conn4 = get(conn, "/api/attachments/photos/revive.png")
      assert json_response(conn4, 200)
    end

    test "rejects invalid base64", %{conn: conn} do
      conn =
        post(conn, "/api/attachments", %{
          path: "bad.png",
          content_base64: "not-valid-base64!!!",
          mtime: 1_000.0
        })

      assert json_response(conn, 400)
    end

    test "rejects oversized attachment (> 5MB)", %{conn: conn} do
      huge = Base.encode64(:crypto.strong_rand_bytes(5 * 1024 * 1024 + 1))

      conn =
        post(conn, "/api/attachments", %{
          # png so MIME whitelist passes; size limit is the gate under test
          path: "huge.png",
          content_base64: huge,
          mtime: 1_000.0
        })

      assert conn.status == 413
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> post("/api/attachments", %{
          path: "nope.png",
          content_base64: @sample_base64,
          mtime: 1.0
        })

      assert json_response(conn, 401)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /attachments/*path — Download
  # ---------------------------------------------------------------------------

  describe "GET /attachments/*path" do
    test "returns attachment with base64 content", %{conn: conn} do
      post(conn, "/api/attachments", %{
        path: "photos/download.png",
        content_base64: @sample_base64,
        mtime: 1_000.0
      })

      conn2 = get(conn, "/api/attachments/photos/download.png")
      body = json_response(conn2, 200)

      assert body["path"] == "photos/download.png"
      assert body["content_base64"] == @sample_base64
      assert body["mime_type"] == "image/png"
      assert body["size_bytes"] == byte_size(@sample_content)
    end

    test "returns 404 for nonexistent attachment", %{conn: conn} do
      conn = get(conn, "/api/attachments/nope/missing.png")
      assert json_response(conn, 404)
    end

    test "returns 404 for soft-deleted attachment", %{conn: conn} do
      post(conn, "/api/attachments", %{
        path: "photos/deleted.png",
        content_base64: @sample_base64,
        mtime: 1_000.0
      })

      delete(conn, "/api/attachments/photos/deleted.png")

      conn3 = get(conn, "/api/attachments/photos/deleted.png")
      assert json_response(conn3, 404)
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE /attachments/*path — Soft-delete
  # ---------------------------------------------------------------------------

  describe "DELETE /attachments/*path" do
    test "soft-deletes an attachment", %{conn: conn} do
      post(conn, "/api/attachments", %{
        path: "photos/todelete.png",
        content_base64: @sample_base64,
        mtime: 1_000.0
      })

      conn2 = delete(conn, "/api/attachments/photos/todelete.png")
      assert %{"deleted" => true, "path" => "photos/todelete.png"} = json_response(conn2, 200)
    end

    test "idempotent — deleting already-deleted returns 200", %{conn: conn} do
      post(conn, "/api/attachments", %{
        path: "photos/double.png",
        content_base64: @sample_base64,
        mtime: 1_000.0
      })

      delete(conn, "/api/attachments/photos/double.png")

      conn3 = delete(conn, "/api/attachments/photos/double.png")
      assert %{"deleted" => true} = json_response(conn3, 200)
    end

    test "deleting nonexistent returns 200 (idempotent)", %{conn: conn} do
      conn = delete(conn, "/api/attachments/photos/ghost.png")
      assert %{"deleted" => true} = json_response(conn, 200)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /attachments/changes — Changes since timestamp
  # ---------------------------------------------------------------------------

  describe "GET /attachments/changes" do
    test "returns changes since timestamp", %{conn: conn} do
      post(conn, "/api/attachments", %{
        path: "photos/change1.png",
        content_base64: @sample_base64,
        mtime: 1_000.0
      })

      conn2 = get(conn, "/api/attachments/changes", %{since: "2020-01-01T00:00:00Z"})
      body = json_response(conn2, 200)

      assert is_list(body["changes"])
      assert body["changes"] != []
      assert is_binary(body["server_time"])

      change = hd(body["changes"])
      assert change["path"] == "photos/change1.png"
      assert is_binary(change["updated_at"])
      assert is_boolean(change["deleted"])
      # Changes should NOT include content
      refute Map.has_key?(change, "content_base64")
    end

    test "includes deleted attachments in changes", %{conn: conn} do
      post(conn, "/api/attachments", %{
        path: "photos/del-change.png",
        content_base64: @sample_base64,
        mtime: 1_000.0
      })

      delete(conn, "/api/attachments/photos/del-change.png")

      conn3 = get(conn, "/api/attachments/changes", %{since: "2020-01-01T00:00:00Z"})
      body = json_response(conn3, 200)

      deleted = Enum.find(body["changes"], &(&1["path"] == "photos/del-change.png"))
      assert deleted["deleted"] == true
    end

    test "returns empty for future timestamp", %{conn: conn} do
      post(conn, "/api/attachments", %{
        path: "photos/future.png",
        content_base64: @sample_base64,
        mtime: 1_000.0
      })

      conn2 = get(conn, "/api/attachments/changes", %{since: "2099-01-01T00:00:00Z"})
      body = json_response(conn2, 200)

      assert body["changes"] == []
    end

    test "returns 400 for invalid timestamp", %{conn: conn} do
      conn = get(conn, "/api/attachments/changes", %{since: "not-a-date"})
      assert json_response(conn, 400)
    end
  end

  # ---------------------------------------------------------------------------
  # Multi-tenant isolation
  # ---------------------------------------------------------------------------

  describe "multi-tenant isolation" do
    test "user B cannot read user A's attachment", %{conn: conn} do
      # Upload as user A (default setup user)
      post(conn, "/api/attachments", %{
        path: "photos/secret.png",
        content_base64: @sample_base64,
        mtime: 1_000.0
      })

      # Create user B with their own vault
      user_b = insert(:user)
      insert(:vault, user: user_b, is_default: true)
      {:ok, api_key_b, _} = Engram.Accounts.create_api_key(user_b, "b-key")

      conn_b =
        build_conn()
        |> put_req_header("authorization", "Bearer #{api_key_b}")

      # User B should not see user A's attachment
      conn_b_get = get(conn_b, "/api/attachments/photos/secret.png")
      assert json_response(conn_b_get, 404)
    end

    test "user B's changes don't include user A's attachments", %{conn: conn} do
      post(conn, "/api/attachments", %{
        path: "photos/private.png",
        content_base64: @sample_base64,
        mtime: 1_000.0
      })

      user_b = insert(:user)
      insert(:vault, user: user_b, is_default: true)
      {:ok, api_key_b, _} = Engram.Accounts.create_api_key(user_b, "b-key")

      conn_b =
        build_conn()
        |> put_req_header("authorization", "Bearer #{api_key_b}")

      conn_b_changes = get(conn_b, "/api/attachments/changes", %{since: "2020-01-01T00:00:00Z"})
      body = json_response(conn_b_changes, 200)

      assert body["changes"] == []
    end
  end
end
