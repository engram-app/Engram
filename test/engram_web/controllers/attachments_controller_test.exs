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
    # Free-tier launch §4.5 — Free gets text-only uploads. Existing happy-
    # path coverage exercises non-text MIMEs (PNG, PDF) that Free can't
    # upload, so seed an active Pro subscription before any upload runs
    # through the controller gate.
    insert(:subscription, user: user, tier: "pro", status: "active")
    _vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)
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
      assert is_binary(att["id"])
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

    test "rejects upload that exceeds per-plan attachment_bytes_cap (§G)",
         %{conn: conn, user: user} do
      # 2 MB total quota; 1.5 MB already used; uploading 800 KB more → over.
      insert(:user_limit_override,
        user: user,
        key: "attachment_bytes_cap",
        value: %{"v" => 2 * 1_048_576}
      )

      first = Base.encode64(:crypto.strong_rand_bytes(1_500_000))

      conn1 =
        post(conn, "/api/attachments", %{
          path: "first.png",
          content_base64: first,
          mtime: 1.0
        })

      assert json_response(conn1, 200)

      second = Base.encode64(:crypto.strong_rand_bytes(800_000))

      conn2 =
        post(conn, "/api/attachments", %{
          path: "second.png",
          content_base64: second,
          mtime: 2.0
        })

      # Free-tier launch §4.5 — standardized LimitResponse shape.
      body = json_response(conn2, 402)
      assert body["error"] == "limit_exceeded"
      assert body["reason"] == "attachments_quota_exceeded"
      assert body["limit_key"] == "attachment_bytes_cap"
      assert body["limit"] == 2 * 1_048_576
      assert body["current"] == 1_500_000
    end

    test "upsert subtracts existing path's size from the lifetime total (§G)",
         %{conn: conn, user: user} do
      insert(:user_limit_override,
        user: user,
        key: "attachment_bytes_cap",
        value: %{"v" => 2 * 1_048_576}
      )

      big = Base.encode64(:crypto.strong_rand_bytes(1_500_000))
      small = Base.encode64(:crypto.strong_rand_bytes(500_000))

      # Upload 1.5 MB at the cap-near.
      assert %{} =
               post(conn, "/api/attachments", %{path: "f.png", content_base64: big, mtime: 1.0})
               |> json_response(200)

      # Replace same path with 500 KB — delta is negative, must succeed.
      assert %{} =
               post(conn, "/api/attachments", %{
                 path: "f.png",
                 content_base64: small,
                 mtime: 2.0
               })
               |> json_response(200)
    end

    test "rejects oversized attachment against per-plan max_file_bytes (§G)",
         %{conn: conn, user: user} do
      # Pin a 1 MB per-file cap for this user; upload 1 MB + 1 byte.
      insert(:user_limit_override,
        user: user,
        key: "max_file_bytes",
        value: %{"v" => 1_048_576}
      )

      huge = Base.encode64(:crypto.strong_rand_bytes(1_048_576 + 1))

      conn =
        post(conn, "/api/attachments", %{
          # png so MIME whitelist passes; size limit is the gate under test
          path: "huge.png",
          content_base64: huge,
          mtime: 1_000.0
        })

      # Free-tier launch §4.5 — single-file too-large now flows through
      # LimitResponse as 402 file_too_large rather than 413.
      body = json_response(conn, 402)
      assert body["error"] == "limit_exceeded"
      assert body["reason"] == "file_too_large"
      assert body["limit_key"] == "max_file_bytes"
      assert body["limit"] == 1_048_576
    end

    test "Free user gets 402 attachment_must_be_text when uploading non-text MIME", %{
      conn: conn,
      user: user
    } do
      # Demote the setup-Pro user back to Free by deleting the subscription.
      # `tier/1` resolves to :free with no subscription row, which lights up
      # the `attachments_text_only` flag per LimitKeys.
      sub =
        Engram.Repo.get_by(Engram.Billing.Subscription, [user_id: user.id],
          skip_tenant_check: true
        )

      Engram.Repo.delete!(sub, skip_tenant_check: true)

      conn =
        post(conn, "/api/attachments", %{
          path: "blocked.png",
          content_base64: @sample_base64,
          mtime: 1.0
        })

      body = json_response(conn, 402)
      assert body["error"] == "limit_exceeded"
      assert body["reason"] == "attachment_must_be_text"
      assert body["limit_key"] == "attachments_text_only"
      assert body["tier"] == "free"
      assert body["limit"] == true
      assert Map.has_key?(body, "upgrade_url")
    end

    test "Free user CAN upload a text/markdown attachment", %{conn: conn, user: user} do
      sub =
        Engram.Repo.get_by(Engram.Billing.Subscription, [user_id: user.id],
          skip_tenant_check: true
        )

      Engram.Repo.delete!(sub, skip_tenant_check: true)

      conn =
        post(conn, "/api/attachments", %{
          path: "notes/readme.md",
          content_base64: Base.encode64("# Free can attach text"),
          mtime: 1.0
        })

      assert %{"attachment" => att} = json_response(conn, 200)
      assert att["path"] == "notes/readme.md"
      assert att["mime_type"] == "text/markdown"
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
      grant_api_write!(user_b)

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
      grant_api_write!(user_b)

      conn_b =
        build_conn()
        |> put_req_header("authorization", "Bearer #{api_key_b}")

      conn_b_changes = get(conn_b, "/api/attachments/changes", %{since: "2020-01-01T00:00:00Z"})
      body = json_response(conn_b_changes, 200)

      assert body["changes"] == []
    end
  end
end
