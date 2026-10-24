defmodule EngramWeb.AttachmentsControllerTest do
  # async: false because AttachmentsTest (also async: false) mutates the
  # global :storage adapter via Application.put_env. ExUnit runs async: true
  # cases first, then async: false serially — making this file async: false
  # serializes it against AttachmentsTest and prevents adapter races where
  # a POST/GET pair straddles a flip to MockStorage or Storage.Database.
  use EngramWeb.ConnCase, async: false

  alias Engram.Attachments

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
    vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    lift_api_rps_cap!(user)
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user, vault: vault}
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

    # `content_hash` has been computed and stored on every write since the
    # encryption work, but no serializer ever returned it — so a client had no
    # way to ask "do you already have these exact bytes?" and force-push paths
    # had no choice but to re-send them. That gap is what let one looping
    # client re-upload the same 667 attachments for 90 minutes on 2026-08-21.
    test "returns content_hash so a client can skip re-sending known bytes", %{conn: conn} do
      conn =
        post(conn, "/api/attachments", %{
          path: "photos/test.png",
          content_base64: @sample_base64,
          mtime: 1_709_234_567.0
        })

      assert %{"attachment" => att} = json_response(conn, 200)
      assert is_binary(att["content_hash"])
      assert att["content_hash"] != ""
    end

    test "the same bytes hash the same, different bytes differ", %{conn: conn} do
      upload = fn path, b64 ->
        conn
        |> post("/api/attachments", %{path: path, content_base64: b64, mtime: 1.0})
        |> json_response(200)
        |> get_in(["attachment", "content_hash"])
      end

      # Stable across paths — the client compares hashes, so an unstable hash
      # would silently reinstate the re-upload loop it exists to prevent.
      assert upload.("a.png", @sample_base64) == upload.("b.png", @sample_base64)
      refute upload.("c.png", @sample_base64) == upload.("d.png", @updated_base64)
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

    test "accepts an unknown extension (detected as octet-stream)", %{conn: conn} do
      conn =
        post(conn, "/api/attachments", %{
          path: "files/data.xyz",
          content_base64: @sample_base64,
          mtime: 1_000.0
        })

      assert %{"attachment" => %{"mime_type" => "application/octet-stream"}} =
               json_response(conn, 200)
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

    test "rejects a mime_type with header-illegal bytes with 422", %{conn: conn} do
      conn =
        post(conn, "/api/attachments", %{
          path: "files/a.txt",
          content_base64: @sample_base64,
          mime_type: "text/plain\r\nx: y",
          mtime: 1_000.0
        })

      assert json_response(conn, 422) == %{"error" => "invalid_mime_type"}
    end

    test "accepts a zip", %{conn: conn} do
      conn =
        post(conn, "/api/attachments", %{
          path: "files/a.zip",
          content_base64: @sample_base64,
          mime_type: "application/zip",
          mtime: 1_000.0
        })

      assert json_response(conn, 200)["attachment"]["mime_type"] == "application/zip"
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

    test "Free user CAN upload a non-text MIME — storage is the lever, not MIME", %{
      conn: conn,
      user: user
    } do
      # Demote the setup-Pro user back to Free by deleting the subscription.
      # `tier/1` resolves to :free with no subscription row. Free now carries
      # `attachments_all_types: true`; the binding limit is the 1 GiB quota.
      sub =
        Engram.Repo.get_by(Engram.Billing.Subscription, [user_id: user.id],
          skip_tenant_check: true
        )

      Engram.Repo.delete!(sub, skip_tenant_check: true)

      conn =
        post(conn, "/api/attachments", %{
          path: "allowed.png",
          content_base64: @sample_base64,
          mtime: 1.0
        })

      assert conn.status in [200, 201]
    end

    test "402 attachment_must_be_text still fires when an override revokes the surface", %{
      conn: conn,
      user: user
    } do
      # No tier defaults to text-only any more, but the gate is still reachable
      # via an operator override — keep the 402 shape under test so the branch
      # can't rot.
      insert(:user_limit_override,
        user: user,
        key: "attachments_all_types",
        value: %{"v" => false},
        reason: "revoke for test",
        set_by: "test"
      )

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
  # POST /attachments with a raw application/octet-stream body (#1877)
  # ---------------------------------------------------------------------------

  describe "POST /attachments (raw octet-stream body)" do
    defp raw_post(conn, query, body) do
      conn
      |> put_req_header("content-type", "application/octet-stream")
      |> post("/api/attachments?" <> URI.encode_query(query), body)
    end

    test "uploads raw bytes with metadata in the query string", %{conn: conn} do
      bytes = :crypto.strong_rand_bytes(4096)

      conn1 = raw_post(conn, %{path: "photos/raw.png", mtime: "1709234567.5"}, bytes)

      assert %{"attachment" => att} = json_response(conn1, 200)
      assert att["path"] == "photos/raw.png"
      assert att["mime_type"] == "image/png"
      assert att["size_bytes"] == 4096

      body = conn |> get("/api/attachments/photos/raw.png") |> json_response(200)
      assert Base.decode64!(body["content_base64"]) == bytes
      assert body["mtime"] == 1_709_234_567.5
    end

    test "stores exactly what the base64 JSON path stores", %{conn: conn} do
      json_att =
        conn
        |> post("/api/attachments", %{
          path: "a.png",
          content_base64: @sample_base64,
          mtime: 1.0
        })
        |> json_response(200)

      raw_att =
        conn
        |> raw_post(%{path: "b.png", mtime: "1.0"}, @sample_content)
        |> json_response(200)

      assert raw_att["attachment"]["content_hash"] == json_att["attachment"]["content_hash"]
      assert raw_att["attachment"]["size_bytes"] == json_att["attachment"]["size_bytes"]
    end

    test "honours an explicit mime_type", %{conn: conn} do
      conn = raw_post(conn, %{path: "doc.bin.pdf", mime_type: "application/pdf"}, "%PDF-1.4")
      assert json_response(conn, 200)["attachment"]["mime_type"] == "application/pdf"
    end

    test "round-trips a unicode / emoji path", %{conn: conn} do
      path = "写真/café 😀.png"
      conn1 = raw_post(conn, %{path: path, mtime: "1.0"}, @sample_content)
      assert json_response(conn1, 200)["attachment"]["path"] == path
    end

    test "sanitizes the path exactly like the JSON path", %{conn: conn} do
      conn1 = raw_post(conn, %{path: "../../etc/evil.png", mtime: "1.0"}, @sample_content)

      assert json_response(conn1, 200)["attachment"]["path"] ==
               Engram.Notes.PathSanitizer.sanitize("../../etc/evil.png")
    end

    test "accepts an empty body as a zero-byte file", %{conn: conn} do
      conn = raw_post(conn, %{path: "empty.png", mtime: "1.0"}, "")
      assert json_response(conn, 200)["attachment"]["size_bytes"] == 0
    end

    test "422 when path is missing", %{conn: conn} do
      conn = raw_post(conn, %{mtime: "1.0"}, @sample_content)
      assert json_response(conn, 422)["error"] == "path is required"
    end

    test "415 for a disallowed extension", %{conn: conn} do
      conn = raw_post(conn, %{path: "evil.exe", mtime: "1.0"}, "MZ")

      assert json_response(conn, 415) == %{
               "error" => "extension_not_allowed",
               "extension" => ".exe"
             }
    end

    test "402 attachment_must_be_text when an override revokes the surface", %{
      conn: conn,
      user: user
    } do
      insert(:user_limit_override,
        user: user,
        key: "attachments_all_types",
        value: %{"v" => false},
        reason: "revoke for test",
        set_by: "test"
      )

      conn = raw_post(conn, %{path: "blocked.png", mtime: "1.0"}, @sample_content)
      assert json_response(conn, 402)["reason"] == "attachment_must_be_text"
    end

    test "a body exactly at max_file_bytes is accepted", %{conn: conn, user: user} do
      insert(:user_limit_override, user: user, key: "max_file_bytes", value: %{"v" => 1024})

      conn = raw_post(conn, %{path: "edge.png", mtime: "1.0"}, :binary.copy("a", 1024))
      assert json_response(conn, 200)["attachment"]["size_bytes"] == 1024
    end

    test "402 file_too_large one byte over max_file_bytes", %{conn: conn, user: user} do
      insert(:user_limit_override, user: user, key: "max_file_bytes", value: %{"v" => 1024})

      conn = raw_post(conn, %{path: "big.png", mtime: "1.0"}, :binary.copy("a", 1025))

      body = json_response(conn, 402)
      assert body["reason"] == "file_too_large"
      assert body["limit_key"] == "max_file_bytes"
      assert body["limit"] == 1024
    end

    test "413 past the request body ceiling, same as the JSON parser", %{conn: conn} do
      # Pro's per-file cap is far above the body ceiling, so the ceiling binds.
      too_big = :binary.copy("a", EngramWeb.Endpoint.max_body_bytes() + 1)
      conn = raw_post(conn, %{path: "huge.png", mtime: "1.0"}, too_big)
      assert json_response(conn, 413)["error"] == "request_too_large"
    end

    test "a declared content-length over max_file_bytes is refused before reading", %{
      conn: conn,
      user: user
    } do
      insert(:user_limit_override, user: user, key: "max_file_bytes", value: %{"v" => 1024})

      conn =
        conn
        |> put_req_header("content-length", "1025")
        |> raw_post(%{path: "lie.png", mtime: "1.0"}, "small")

      assert json_response(conn, 402)["reason"] == "file_too_large"
      assert json_response(conn, 402)["limit"] == 1024
    end

    test "a declared content-length over the body ceiling is 413 before reading", %{conn: conn} do
      declared = Integer.to_string(EngramWeb.Endpoint.max_body_bytes() + 1)

      conn =
        conn
        |> put_req_header("content-length", declared)
        |> raw_post(%{path: "lie.png", mtime: "1.0"}, "small")

      assert json_response(conn, 413)["error"] == "request_too_large"
      assert get_resp_header(conn, "connection") == ["close"]
    end

    # The body below is 5 bytes: read, it would fit the quota. Only the
    # declared length can make this a 402, so a 402 proves no read happened.
    test "a declared content-length over the remaining quota is 402 before reading", %{
      conn: conn,
      user: user
    } do
      insert(:user_limit_override, user: user, key: "attachment_bytes_cap", value: %{"v" => 2000})
      assert json_response(raw_post(conn, %{path: "first.png"}, :binary.copy("a", 1500)), 200)

      conn =
        conn
        |> put_req_header("content-length", "1000")
        |> raw_post(%{path: "second.png", mtime: "1.0"}, "small")

      body = json_response(conn, 402)
      assert body["reason"] == "attachments_quota_exceeded"
      assert body["limit"] == 2000
      assert body["current"] == 1500
    end

    test "the early quota check nets out the file being replaced", %{conn: conn, user: user} do
      insert(:user_limit_override, user: user, key: "attachment_bytes_cap", value: %{"v" => 2000})
      assert json_response(raw_post(conn, %{path: "f.png"}, :binary.copy("a", 1500)), 200)

      # 1500 used + 1000 declared > 2000, but it replaces the 1500.
      conn = raw_post(conn, %{path: "f.png", mtime: "2.0"}, :binary.copy("b", 1000))
      assert json_response(conn, 200)["attachment"]["size_bytes"] == 1000
    end

    # Same size as the stored file may be the same bytes, which the upload
    # answers as a no-op 200 even over quota; only a read can tell.
    test "the early quota check never refuses a same-size re-upload", %{conn: conn, user: user} do
      assert json_response(raw_post(conn, %{path: "f.png"}, :binary.copy("a", 1500)), 200)
      # Quota drops below what is already stored (e.g. a downgrade).
      insert(:user_limit_override, user: user, key: "attachment_bytes_cap", value: %{"v" => 1000})

      conn = raw_post(conn, %{path: "f.png", mtime: "2.0"}, :binary.copy("a", 1500))
      assert json_response(conn, 200)["attachment"]["size_bytes"] == 1500
    end

    test "a text-only plan's non-text upload is 402 without reading the body", %{
      conn: conn,
      user: user
    } do
      insert(:user_limit_override,
        user: user,
        key: "attachments_all_types",
        value: %{"v" => false},
        reason: "revoke for test",
        set_by: "test"
      )

      declared = Integer.to_string(EngramWeb.Endpoint.max_body_bytes() + 1)

      conn =
        conn
        |> put_req_header("content-length", declared)
        |> raw_post(%{path: "photo.png", mtime: "1.0"}, "PNG")

      assert json_response(conn, 402)["reason"] == "attachment_must_be_text"
      {Plug.Adapters.Test.Conn, state} = conn.adapter
      assert state.req_body == "PNG"
    end

    for bad <- ["NaN", "1,5", "", "inf", "1e400"] do
      test "422 for mtime #{inspect(bad)} and nothing is stored", %{conn: conn} do
        conn1 = raw_post(conn, %{path: "m.png", mtime: unquote(bad)}, @sample_content)
        assert json_response(conn1, 422)["error"] == "mtime must be a finite number"

        assert conn |> get("/api/attachments/m.png") |> json_response(404)
      end
    end

    test "422 for a non-string mime_type, raw or JSON", %{conn: conn} do
      conn1 =
        conn
        |> put_req_header("content-type", "application/octet-stream")
        |> post("/api/attachments?path=m.png&mime_type[]=image/png", @sample_content)

      assert json_response(conn1, 422)["error"] == "mime_type must be a string"

      conn2 =
        post(conn, "/api/attachments", %{
          path: "m.png",
          content_base64: @sample_base64,
          mime_type: %{"a" => "b"}
        })

      assert json_response(conn2, 422)["error"] == "mime_type must be a string"
      assert conn |> get("/api/attachments/m.png") |> json_response(404)
    end

    test "an absent mtime stores nil, as on the JSON path", %{conn: conn} do
      conn1 = raw_post(conn, %{path: "nomtime.png"}, @sample_content)
      assert json_response(conn1, 200)

      body = conn |> get("/api/attachments/nomtime.png") |> json_response(200)
      assert body["mtime"] == nil
    end

    test "an early refusal drains the unread body first", %{conn: conn} do
      conn = raw_post(conn, %{path: "evil.exe", mtime: "1.0"}, :binary.copy("a", 4096))

      assert json_response(conn, 415)
      {Plug.Adapters.Test.Conn, state} = conn.adapter
      assert state.req_body == ""
      assert get_resp_header(conn, "connection") == []
    end

    test "an early refusal past the ceiling closes instead of draining", %{conn: conn} do
      declared = Integer.to_string(EngramWeb.Endpoint.max_body_bytes() + 1)

      conn =
        conn
        |> put_req_header("content-length", declared)
        |> raw_post(%{path: "evil.exe", mtime: "1.0"}, "MZ")

      assert json_response(conn, 415)
      {Plug.Adapters.Test.Conn, state} = conn.adapter
      assert state.req_body == "MZ"
      assert get_resp_header(conn, "connection") == ["close"]
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> raw_post(%{path: "nope.png"}, @sample_content)

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

    # content_base64 is emitted as a pre-quoted Jason.Fragment so Jason does not
    # escape-scan a multi-MB string. The wire bytes must not change: compare
    # against the plain-string encoding of the same map, byte for byte.
    test "JSON body is byte-identical to the plain-string encoding",
         %{conn: conn, user: user, vault: vault} do
      bytes = :crypto.strong_rand_bytes(70_000) <> <<0, 255, ?", ?\\, ?/>>

      conn
      |> put_req_header("content-type", "application/octet-stream")
      |> post("/api/attachments?path=bin/r.png&mtime=12.5", bytes)
      |> json_response(200)

      {:ok, att} = Attachments.get_attachment(user, vault, "bin/r.png")

      expected =
        Jason.encode!(%{
          id: att.id,
          path: att.path,
          mime_type: att.mime_type,
          size_bytes: att.size_bytes,
          mtime: att.mtime,
          content_hash: att.content_hash,
          content_base64: Base.encode64(bytes),
          created_at: att.created_at,
          updated_at: att.updated_at
        })

      resp = get(conn, "/api/attachments/bin/r.png")
      assert resp.status == 200
      assert resp.resp_body == expected
      assert Base.decode64!(json_response(resp, 200)["content_base64"]) == bytes
    end

    test "JSON body for an empty attachment carries an empty content_base64",
         %{conn: conn} do
      post(conn, "/api/attachments", %{path: "e.txt", content_base64: "", mtime: 1.0})
      body = json_response(get(conn, "/api/attachments/e.txt"), 200)
      assert body["content_base64"] == ""
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

    test "a delete that could not run is a 500, not deleted: true", %{conn: conn, user: user} do
      Engram.Crypto.DekCache.invalidate(user.id)

      {:ok, _} =
        user
        |> Ecto.Changeset.change(encrypted_dek: :crypto.strong_rand_bytes(32))
        |> Engram.Repo.update(skip_tenant_check: true)

      conn = delete(conn, "/api/attachments/photos/any.png")
      assert %{"error" => "failed to delete attachment"} = json_response(conn, 500)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /attachments/changes — retired timestamp feed
  # ---------------------------------------------------------------------------

  # #2159: a live row whose blob is gone is permanent until restored, so a
  # client must not retry it as a transient 5xx.
  describe "GET /attachments/*path with the blob missing" do
    import ExUnit.CaptureLog

    setup %{conn: conn, user: user, vault: vault} do
      post(conn, "/api/attachments", %{path: "gone.png", content_base64: @sample_base64})
      {:ok, att} = Attachments.get_attachment(user, vault, "gone.png")
      :ok = Engram.Storage.adapter().delete(att.storage_key)
      :ok
    end

    test "returns 410 with code blob_missing", %{conn: conn} do
      body = conn |> get("/api/attachments/gone.png") |> json_response(410)
      assert body["code"] == "blob_missing"
      assert is_binary(body["error"])
    end

    test "?raw=1 returns the same 410", %{conn: conn} do
      body = conn |> get("/api/attachments/gone.png?raw=1") |> json_response(410)
      assert body["code"] == "blob_missing"
    end

    # engram-infra alert rules match this literal line; renaming it silences them.
    test "logs the alerted line", %{conn: conn} do
      log = capture_log(fn -> get(conn, "/api/attachments/gone.png") end)
      assert log =~ "Attachment blob missing for live row"
    end
  end

  describe "GET /attachments/*path on a transient storage error" do
    test "stays 502", %{conn: conn} do
      post(conn, "/api/attachments", %{path: "flaky.png", content_base64: @sample_base64})

      prev = Application.get_env(:engram, :storage)
      Application.put_env(:engram, :storage, Engram.MockStorage)
      on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
      Mox.stub(Engram.MockStorage, :get, fn _key -> {:error, :timeout} end)

      body = conn |> get("/api/attachments/flaky.png") |> json_response(502)
      refute Map.has_key?(body, "code")
    end
  end

  describe "GET /attachments/changes (retired)" do
    test "returns 410 Gone regardless of params", %{conn: conn} do
      resp =
        conn
        |> get("/api/attachments/changes", %{since: "2000-01-01T00:00:00Z"})
        |> json_response(410)

      assert %{"error" => "gone", "message" => message} = resp
      assert message =~ "sync socket"

      # 410 must not depend on params
      assert %{"error" => "gone"} =
               conn |> get("/api/attachments/changes") |> json_response(410)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /attachments — List (index)
  # ---------------------------------------------------------------------------

  describe "GET /attachments (index)" do
    test "lists non-deleted attachments", %{conn: conn} do
      conn
      |> post("/api/attachments", %{
        path: "diagrams/arch.png",
        content_base64: Base.encode64("PNG"),
        mtime: 1_000.0
      })
      |> json_response(200)

      resp = conn |> get("/api/attachments") |> json_response(200)

      assert [%{"path" => "diagrams/arch.png", "mime_type" => "image/png"} = a] =
               resp["attachments"]

      assert a["size_bytes"] == 3
      assert Map.has_key?(a, "updated_at")
      assert is_binary(a["id"])
    end

    test "returns empty list for a vault with no attachments", %{conn: conn} do
      resp = conn |> get("/api/attachments") |> json_response(200)
      assert resp["attachments"] == []
    end

    test "the listing carries content_hash", %{conn: conn} do
      # The index is what a client sweeps before deciding what to push. Without
      # a hash here it must either trust its own local stamp or re-send
      # everything — and the force-push paths chose re-send.
      conn
      |> post("/api/attachments", %{
        path: "diagrams/arch.png",
        content_base64: Base.encode64("PNG"),
        mtime: 1_000.0
      })
      |> json_response(200)

      assert [a] = conn |> get("/api/attachments") |> json_response(200) |> Map.get("attachments")
      assert is_binary(a["content_hash"])
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> get("/api/attachments")

      assert conn.status in [401, 403]
    end
  end

  # ---------------------------------------------------------------------------
  # GET /attachments/*path?raw=1 — Raw byte streaming
  # ---------------------------------------------------------------------------

  describe "GET /attachments/*path?raw=1" do
    test "streams raw bytes with the attachment Content-Type", %{conn: conn} do
      _ =
        conn
        |> post("/api/attachments", %{
          path: "p.png",
          content_base64: Base.encode64("RAWBYTES"),
          mtime: 1.0
        })
        |> json_response(200)

      resp = get(conn, "/api/attachments/p.png?raw=1")

      assert resp.status == 200
      assert response_content_type(resp, :png) =~ "image/png"
      assert resp.resp_body == "RAWBYTES"
      assert get_resp_header(resp, "content-disposition") == [~s(inline; filename="p.png")]
    end

    # The plugin downloads raw when the join reply advertises
    # raw_attachment_download, so the raw response must carry the metadata the
    # JSON body did, with the SAME values, and keep every security header.
    test "carries the JSON body's metadata in x-engram-* headers",
         %{conn: conn, user: user, vault: vault} do
      bytes = :crypto.strong_rand_bytes(4096) <> <<0, 255>>

      conn
      |> put_req_header("content-type", "application/octet-stream")
      |> post("/api/attachments?path=d/r%C3%A9.png&mtime=1709234567.125", bytes)
      |> json_response(200)

      json = json_response(get(conn, "/api/attachments/d/r%C3%A9.png"), 200)
      {:ok, att} = Attachments.get_attachment(user, vault, "d/ré.png")
      assert is_binary(att.content_hash)

      resp = get(conn, "/api/attachments/d/r%C3%A9.png?raw=1")

      assert resp.status == 200
      assert resp.resp_body == bytes
      assert resp.resp_body == Base.decode64!(json["content_base64"])
      assert get_resp_header(resp, "x-engram-content-hash") == [json["content_hash"]]
      assert get_resp_header(resp, "x-engram-mime-type") == [json["mime_type"]]
      assert get_resp_header(resp, "x-engram-updated-at") == [json["updated_at"]]
      [mtime] = get_resp_header(resp, "x-engram-mtime")
      assert Jason.decode!(mtime) == json["mtime"]

      # Security headers of the raw path are untouched.
      assert get_resp_header(resp, "x-content-type-options") == ["nosniff"]
      assert [csp] = get_resp_header(resp, "content-security-policy")
      assert csp =~ "default-src 'none'"
      assert get_resp_header(resp, "content-disposition") == [~s(inline; filename="ré.png")]
    end

    test "omits x-engram-mtime when the attachment has none", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      conn
      |> put_req_header("content-type", "application/octet-stream")
      |> post("/api/attachments?path=n.png", "x")
      |> json_response(200)

      {:ok, att} = Attachments.get_attachment(user, vault, "n.png")
      resp = get(conn, "/api/attachments/n.png?raw=1")

      if is_nil(att.mtime),
        do: assert(get_resp_header(resp, "x-engram-mtime") == []),
        else: assert(get_resp_header(resp, "x-engram-mtime") == [Jason.encode!(att.mtime)])

      assert [_] = get_resp_header(resp, "x-engram-updated-at")
    end

    test "marks an already-compressed body no-transform so Bandit skips gzip",
         %{conn: conn} do
      # The pure predicate is covered in AttachmentCompressionTest; this is the
      # WIRING check — without the `maybe_skip_compression/2` call in show/2
      # everything else stays green while Bandit happily re-deflates every PNG.
      _ =
        conn
        |> post("/api/attachments", %{
          path: "p.png",
          content_base64: Base.encode64("RAWBYTES"),
          mtime: 1.0
        })
        |> json_response(200)

      resp = get(conn, "/api/attachments/p.png?raw=1")

      [cache_control] = get_resp_header(resp, "cache-control")
      directives = Plug.Conn.Utils.list(cache_control)

      assert "no-transform" in directives
      # Phoenix's default directives must SURVIVE. Replacing the header instead
      # of appending would strip `private` off attachment bytes as a side
      # effect of a CPU fix — the whole point of asserting the list, not the
      # string.
      assert "private" in directives
      assert "must-revalidate" in directives
    end

    test "leaves compressible bodies alone — gzip still earns its keep", %{conn: conn} do
      _ =
        conn
        |> post("/api/attachments", %{
          path: "notes.txt",
          content_base64: Base.encode64("plain text, very compressible"),
          mime_type: "text/plain",
          mtime: 1.0
        })
        |> json_response(200)

      resp = get(conn, "/api/attachments/notes.txt?raw=1")

      [cache_control] = get_resp_header(resp, "cache-control")
      refute "no-transform" in Plug.Conn.Utils.list(cache_control)
    end

    test "forces download for inline-script types (svg)", %{conn: conn} do
      _ =
        conn
        |> post("/api/attachments", %{
          path: "diagram.svg",
          content_base64: Base.encode64("<svg/>"),
          mime_type: "image/svg+xml",
          mtime: 1.0
        })
        |> json_response(200)

      resp = get(conn, "/api/attachments/diagram.svg?raw=1")

      assert resp.status == 200

      assert get_resp_header(resp, "content-disposition") == [
               ~s(attachment; filename="diagram.svg")
             ]
    end

    test "forces download for svg carrying a charset parameter", %{conn: conn} do
      # `mime_type` is stored verbatim from the uploader, so the SVG exclusion
      # must not be an exact-string match: `image/svg+xml; charset=utf-8` and
      # `image/svg+xml ` used to miss it and fall through to the
      # `starts_with?("image/")` allowlist, serving a script-executing document
      # `inline`. Not exploitable on its own (the :api pipeline sets
      # `default-src 'none'` and the route is Bearer-only, so there is no
      # drive-by), but it is the defense-in-depth layer, so it must hold.
      for {path, mime} <- [
            {"param.svg", "image/svg+xml; charset=utf-8"},
            {"trail.svg", "image/svg+xml "},
            {"upper.svg", "IMAGE/SVG+XML"}
          ] do
        _ =
          conn
          |> post("/api/attachments", %{
            path: path,
            content_base64: Base.encode64("<svg/>"),
            mime_type: mime,
            mtime: 1.0
          })
          |> json_response(200)

        resp = get(conn, "/api/attachments/#{path}?raw=1")

        assert resp.status == 200

        assert get_resp_header(resp, "content-disposition") == [
                 ~s(attachment; filename="#{path}")
               ],
               "#{inspect(mime)} was served inline"
      end
    end

    test "charset parameter renders text/plain inline (behaviour change)", %{conn: conn} do
      # The other direction of the normalization, pinned because it is a real
      # behaviour CHANGE, not just a hole being closed: browsers commonly send
      # `text/plain; charset=utf-8`, which previously missed the bare
      # `"text/plain"` equality check and was force-downloaded. It now
      # normalizes to `text/plain` and renders inline, matching bare
      # `text/plain`, which is the point of normalizing.
      #
      # Safe: `text/plain` cannot execute script, and the :api pipeline serves
      # it under `default-src 'none'` + nosniff regardless.
      _ =
        conn
        |> post("/api/attachments", %{
          path: "notes.txt",
          content_base64: Base.encode64("hello"),
          mime_type: "text/plain; charset=utf-8",
          mtime: 1.0
        })
        |> json_response(200)

      resp = get(conn, "/api/attachments/notes.txt?raw=1")

      assert resp.status == 200

      assert get_resp_header(resp, "content-disposition") == [
               ~s(inline; filename="notes.txt")
             ]
    end

    test "forces download for text/* markup types (allowlist, not just svg/html)", %{conn: conn} do
      # text/xml is admitted by the MIME whitelist's `text/` prefix and can run
      # script via XSLT — it must NOT render inline.
      _ =
        conn
        |> post("/api/attachments", %{
          path: "data.xml",
          content_base64: Base.encode64("<?xml version=\"1.0\"?><root/>"),
          mime_type: "text/xml",
          mtime: 1.0
        })
        |> json_response(200)

      resp = get(conn, "/api/attachments/data.xml?raw=1")

      assert resp.status == 200
      assert get_resp_header(resp, "content-disposition") == [~s(attachment; filename="data.xml")]
    end

    test "without raw still returns JSON with content_base64", %{conn: conn} do
      _ =
        conn
        |> post("/api/attachments", %{
          path: "q.png",
          content_base64: Base.encode64("BYTES"),
          mtime: 1.0
        })
        |> json_response(200)

      resp = conn |> get("/api/attachments/q.png") |> json_response(200)
      assert resp["content_base64"] == Base.encode64("BYTES")
    end
  end

  # ---------------------------------------------------------------------------
  # POST /attachments/rename — Rename / Move single attachment
  # ---------------------------------------------------------------------------

  describe "POST /attachments/rename" do
    test "moves and returns new path", %{conn: conn, user: user, vault: vault} do
      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "old/a.png",
          "content_base64" => Base.encode64("D"),
          "mime_type" => "image/png",
          "mtime" => 1.0
        })

      conn =
        post(conn, "/api/attachments/rename", %{
          "old_path" => "old/a.png",
          "new_path" => "new/b.png"
        })

      body = json_response(conn, 200)
      assert body["renamed"] == true
      assert body["old_path"] == "old/a.png"
      assert body["new_path"] == "new/b.png"
      # Response carries the renamed attachment's metadata (parity with notes).
      assert body["attachment"]["path"] == "new/b.png"
      assert body["attachment"]["mime_type"] == "image/png"
    end

    test "conflict → 409", %{conn: conn, user: user, vault: vault} do
      for p <- ["a.png", "b.png"] do
        {:ok, _} =
          Attachments.upsert_attachment(user, vault, %{
            "path" => p,
            "content_base64" => Base.encode64(p),
            "mime_type" => "image/png",
            "mtime" => 1.0
          })
      end

      conn =
        post(conn, "/api/attachments/rename", %{"old_path" => "a.png", "new_path" => "b.png"})

      assert json_response(conn, 409)["error"] == "conflict"
    end

    test "not_found → 404", %{conn: conn} do
      conn =
        post(conn, "/api/attachments/rename", %{"old_path" => "ghost.png", "new_path" => "x.png"})

      assert json_response(conn, 404)["error"] == "not_found"
    end

    test "onto an executable extension → 415, nothing moves", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{path: "notes.txt", content: "MZ"})

      assert %{"error" => "extension_not_allowed", "extension" => ".exe"} =
               conn
               |> post("/api/attachments/rename", %{
                 "old_path" => "notes.txt",
                 "new_path" => "evil.exe."
               })
               |> json_response(415)

      {:ok, metas} = Attachments.list_attachments(Engram.Repo.reload!(user), vault)
      assert Enum.map(metas, & &1.path) == ["notes.txt"]
    end
  end

  # ---------------------------------------------------------------------------
  # POST /attachments/batch-move + batch-delete — Batch ops (IdempotencyKey)
  # ---------------------------------------------------------------------------

  describe "POST /attachments/batch-move" do
    test "requires idempotency key → 400", %{conn: conn} do
      conn =
        post(conn, "/api/attachments/batch-move", %{
          "paths" => ["a.png"],
          "target_folder" => "img"
        })

      assert json_response(conn, 400)["error"] == "missing_idempotency_key"
    end

    test "moves attachments into target folder", %{conn: conn, user: user, vault: vault} do
      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "a.png",
          "content_base64" => Base.encode64("A"),
          "mime_type" => "image/png",
          "mtime" => 1.0
        })

      conn =
        conn
        |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
        |> post("/api/attachments/batch-move", %{"paths" => ["a.png"], "target_folder" => "img"})

      body = json_response(conn, 200)
      assert body["moved"] == 1
    end

    test "sanitizes the target folder", %{conn: conn, user: user, vault: vault} do
      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "a.png",
          "content_base64" => Base.encode64("A"),
          "mime_type" => "image/png",
          "mtime" => 1.0
        })

      conn
      |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
      |> post("/api/attachments/batch-move", %{
        "paths" => ["a.png"],
        "target_folder" => "%2e%2e/img"
      })
      |> json_response(200)

      {:ok, metas} = Attachments.list_attachments(Engram.Repo.reload!(user), vault)
      assert Enum.map(metas, & &1.path) == ["img/a.png"]
    end

    test "a target that cleans to empty is 422 and moves nothing", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "keep/a.png",
          "content_base64" => Base.encode64("A"),
          "mime_type" => "image/png",
          "mtime" => 1.0
        })

      for bad <- ["..", "%2e%2e", "./.."] do
        body =
          conn
          |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
          |> post("/api/attachments/batch-move", %{
            "paths" => ["keep/a.png"],
            "target_folder" => bad
          })
          |> json_response(422)

        assert body["error"] == "invalid_path"
      end

      {:ok, metas} = Attachments.list_attachments(Engram.Repo.reload!(user), vault)
      assert Enum.map(metas, & &1.path) == ["keep/a.png"]
    end
  end

  describe "POST /attachments/batch-move of a blocked file" do
    setup do
      prev = Application.get_env(:engram, :attachment_mime_bypass)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:engram, :attachment_mime_bypass, prev),
          else: Application.delete_env(:engram, :attachment_mime_bypass)
      end)
    end

    test "is 415 and moves nothing", %{conn: conn, user: user, vault: vault} do
      # Stored while an operator had the bypass on.
      Application.put_env(:engram, :attachment_mime_bypass, true)
      {:ok, _} = Attachments.upsert_attachment(user, vault, %{path: "tool.exe", content: "MZ"})
      Application.delete_env(:engram, :attachment_mime_bypass)

      assert %{"error" => "extension_not_allowed", "extension" => ".exe"} =
               conn
               |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
               |> post("/api/attachments/batch-move", %{
                 "paths" => ["tool.exe"],
                 "target_folder" => "bin"
               })
               |> json_response(415)

      {:ok, metas} = Attachments.list_attachments(Engram.Repo.reload!(user), vault)
      assert Enum.map(metas, & &1.path) == ["tool.exe"]
    end
  end

  describe "POST /attachments/batch-delete" do
    test "requires idempotency key → 400", %{conn: conn} do
      conn = post(conn, "/api/attachments/batch-delete", %{"paths" => ["a.png"]})
      assert json_response(conn, 400)["error"] == "missing_idempotency_key"
    end

    test "deletes attachments", %{conn: conn, user: user, vault: vault} do
      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "b.png",
          "content_base64" => Base.encode64("B"),
          "mime_type" => "image/png",
          "mtime" => 1.0
        })

      conn =
        conn
        |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
        |> post("/api/attachments/batch-delete", %{"paths" => ["b.png"]})

      body = json_response(conn, 200)
      assert body["deleted"] == 1
      # The attachment is actually gone, not just counted.
      assert {:ok, nil} = Attachments.get_attachment(user, vault, "b.png")
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
      lift_api_rps_cap!(user_b)

      conn_b =
        build_conn()
        |> put_req_header("authorization", "Bearer #{api_key_b}")

      # User B should not see user A's attachment
      conn_b_get = get(conn_b, "/api/attachments/photos/secret.png")
      assert json_response(conn_b_get, 404)
    end

    test "user B's sync manifest excludes user A's attachments", %{conn: conn} do
      post(conn, "/api/attachments", %{
        path: "photos/secret.png",
        content_base64: @sample_base64,
        mtime: 1_000.0
      })

      user_b = insert(:user)
      insert(:vault, user: user_b, is_default: true)
      {:ok, api_key_b, _} = Engram.Accounts.create_api_key(user_b, "b-key")
      lift_api_rps_cap!(user_b)

      conn_b =
        build_conn()
        |> put_req_header("authorization", "Bearer #{api_key_b}")

      # The only remaining attachment LIST surface: cross-user isolation on
      # it was previously pinned via the retired GET /attachments/changes.
      body = json_response(get(conn_b, "/api/sync/manifest"), 200)
      assert body["attachments"] == []
    end
  end

  # ---------------------------------------------------------------------------
  # DEK rotation lock
  # ---------------------------------------------------------------------------

  describe "POST /attachments while a DEK rotation holds the user" do
    import Ecto.Query, only: [from: 2]
    import Mox

    alias Engram.Attachments.Attachment
    alias Engram.Repo
    alias Engram.Storage.InMemory

    defp set_rotation_lock(user, at) do
      Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^user.id),
        [set: [dek_rotation_locked_at: at]],
        skip_tenant_check: true
      )

      # The auth path serves the user from the :user cache.
      Engram.Accounts.evict_user(user.id)
    end

    defp live_rows(user),
      do: Repo.all(from(a in Attachment, where: a.user_id == ^user.id), skip_tenant_check: true)

    defp upload(conn),
      do: post(conn, "/api/attachments", %{path: "r.png", content_base64: @sample_base64})

    test "is 503 rotation_in_progress and writes nothing; succeeds once cleared", %{
      conn: conn,
      user: user
    } do
      set_rotation_lock(user, DateTime.utc_now(:second))
      resp = upload(conn)
      assert %{"error" => "rotation_in_progress"} = json_response(resp, 503)
      assert get_resp_header(resp, "retry-after") == ["60"]
      assert live_rows(user) == []

      set_rotation_lock(user, nil)
      assert conn |> upload() |> json_response(200)
    end

    # The request plug saw no lock; the rotation starts while the bytes are
    # stored, before the locked row write.
    test "a rotation that starts mid-request is refused at the row write", %{
      conn: conn,
      user: user
    } do
      prev = Application.get_env(:engram, :storage)
      Application.put_env(:engram, :storage, Engram.MockStorage)
      on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
      stub_with(Engram.MockStorage, InMemory)

      test_pid = self()

      stub(Engram.MockStorage, :put, fn key, bin, opts ->
        send(test_pid, {:stored, key})
        set_rotation_lock(user, DateTime.utc_now(:second))
        InMemory.put(key, bin, opts)
      end)

      # The write's own tenant transaction sees the lock and raises, rendered
      # as the same 503 the request plug answers with.
      {503, headers, body} = assert_error_sent(503, fn -> upload(conn) end)
      assert %{"error" => "rotation_in_progress"} = Jason.decode!(body)
      assert {"retry-after", "60"} in headers
      assert live_rows(user) == []

      # The blob stored before the refusal is not left orphaned.
      assert_received {:stored, key}
      refute InMemory.exists?(key)
    end

    # A rotation that already finished (lock clear, DEK version moved)
    # between the DEK read and the row write.
    test "a rotation that completes mid-request is refused at the row write", %{
      conn: conn,
      user: user
    } do
      prev = Application.get_env(:engram, :storage)
      Application.put_env(:engram, :storage, Engram.MockStorage)
      on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
      stub_with(Engram.MockStorage, InMemory)

      stub(Engram.MockStorage, :put, fn k, bin, opts ->
        Repo.update_all(
          from(u in Engram.Accounts.User, where: u.id == ^user.id),
          [inc: [dek_version: 1]],
          skip_tenant_check: true
        )

        InMemory.put(k, bin, opts)
      end)

      resp = upload(conn)
      assert %{"error" => "rotation_in_progress"} = json_response(resp, 503)
      assert live_rows(user) == []
    end

    test "a refused overwrite leaves the existing attachment readable", %{
      conn: conn,
      user: user
    } do
      original = conn |> upload() |> json_response(200)
      [%{storage_key: key}] = live_rows(user)

      prev = Application.get_env(:engram, :storage)
      Application.put_env(:engram, :storage, Engram.MockStorage)
      on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
      stub_with(Engram.MockStorage, InMemory)

      stub(Engram.MockStorage, :put, fn k, bin, opts ->
        set_rotation_lock(user, DateTime.utc_now(:second))
        InMemory.put(k, bin, opts)
      end)

      {503, _headers, body} =
        assert_error_sent(503, fn ->
          post(conn, "/api/attachments", %{path: "r.png", content_base64: @updated_base64})
        end)

      assert %{"error" => "rotation_in_progress"} = Jason.decode!(body)
      assert [%{storage_key: ^key}] = live_rows(user)

      set_rotation_lock(user, nil)
      raw = get(conn, "/api/attachments/r.png?raw=1")
      assert response(raw, 200) == @sample_content

      assert original["attachment"]["content_hash"] ==
               get_resp_header(raw, "x-engram-content-hash") |> hd()
    end
  end

  # ---------------------------------------------------------------------------
  # GET /attachments/*path for format v2 (segmented, chunked uploads)
  # ---------------------------------------------------------------------------

  describe "GET /attachments/*path (v2 segmented)" do
    import ExUnit.CaptureLog

    alias Engram.Attachments.{Attachment, SegmentedCipher, Uploads}
    alias Engram.Repo
    alias Engram.Storage.InMemory

    @seg 8 * 1024 * 1024
    # Two segments, 11.5 MB: over the 11 MB single-request ceiling.
    @big @seg + 3 * 1024 * 1024

    setup %{user: user, vault: vault} do
      insert(:user_limit_override,
        user: user,
        key: "max_file_bytes",
        value: %{"v" => 100 * 1024 * 1024}
      )

      bytes = :crypto.strong_rand_bytes(@big)
      att = upload_v2(user, vault, "videos/clip.mp4", bytes)
      %{bytes: bytes, att: att}
    end

    defp upload_v2(user, vault, path, bytes) do
      {:ok, up} =
        Uploads.start(user, vault, %{path: path, size_bytes: byte_size(bytes), mtime: 1.0})

      for {part, n} <- Enum.with_index(chunk(bytes), 1),
          do: {:ok, _} = Uploads.put_part(user, vault, up.id, n, part)

      {:ok, att} = Uploads.complete(user, vault, up.id)
      Repo.get!(Attachment, att.id, skip_tenant_check: true)
    end

    defp chunk(<<part::binary-size(@seg), rest::binary>>) when rest != "",
      do: [part | chunk(rest)]

    defp chunk(last), do: [last]

    test "?raw=1 streams the plaintext with the metadata headers", %{
      conn: conn,
      bytes: bytes,
      att: att
    } do
      resp = get(conn, "/api/attachments/videos/clip.mp4?raw=1")

      assert resp.status == 200
      assert resp.state == :chunked
      assert resp.resp_body == bytes
      assert get_resp_header(resp, "x-engram-content-hash") == [att.content_hash]
      assert get_resp_header(resp, "content-length") == [Integer.to_string(@big)]
      assert get_resp_header(resp, "accept-ranges") == ["bytes"]
      assert get_resp_header(resp, "content-disposition") == [~s(attachment; filename="clip.mp4")]
    end

    test "Range: bytes=N- from a segment boundary is 206 with segment 2 onward", %{
      conn: conn,
      bytes: bytes
    } do
      resp =
        conn
        |> put_req_header("range", "bytes=#{@seg}-")
        |> get("/api/attachments/videos/clip.mp4?raw=1")

      assert resp.status == 206
      assert resp.resp_body == binary_part(bytes, @seg, @big - @seg)
      assert get_resp_header(resp, "content-range") == ["bytes #{@seg}-#{@big - 1}/#{@big}"]
      assert get_resp_header(resp, "content-length") == [Integer.to_string(@big - @seg)]
    end

    test "Range: bytes=N-M across a boundary returns exactly those bytes", %{
      conn: conn,
      bytes: bytes
    } do
      {first, last} = {@seg - 5, @seg + 9}

      resp =
        conn
        |> put_req_header("range", "bytes=#{first}-#{last}")
        |> get("/api/attachments/videos/clip.mp4?raw=1")

      assert resp.status == 206
      assert resp.resp_body == binary_part(bytes, first, last - first + 1)
      assert get_resp_header(resp, "content-range") == ["bytes #{first}-#{last}/#{@big}"]
    end

    test "Range end past the file is clamped to the last byte", %{conn: conn, bytes: bytes} do
      resp =
        conn
        |> put_req_header("range", "bytes=#{@big - 3}-#{@big * 2}")
        |> get("/api/attachments/videos/clip.mp4?raw=1")

      assert resp.status == 206
      assert resp.resp_body == binary_part(bytes, @big - 3, 3)
      assert get_resp_header(resp, "content-range") == ["bytes #{@big - 3}-#{@big - 1}/#{@big}"]
    end

    test "a Range starting at or past the end is 416", %{conn: conn} do
      resp =
        conn
        |> put_req_header("range", "bytes=#{@big}-")
        |> get("/api/attachments/videos/clip.mp4?raw=1")

      assert resp.status == 416
      assert get_resp_header(resp, "content-range") == ["bytes */#{@big}"]
    end

    test "multi-range and suffix forms are ignored: 200 with the full body", %{
      conn: conn,
      bytes: bytes
    } do
      for range <- ["bytes=0-1,5-6", "bytes=-100", "items=0-1", "bytes=9-3"] do
        resp =
          conn
          |> put_req_header("range", range)
          |> get("/api/attachments/videos/clip.mp4?raw=1")

        assert resp.status == 200, range
        assert resp.resp_body == bytes
      end
    end

    test "JSON show above the single-request ceiling is 409 use_raw_download", %{conn: conn} do
      assert %{"error" => "use_raw_download"} =
               conn |> get("/api/attachments/videos/clip.mp4") |> json_response(409)
    end

    test "JSON show of a small v2 row returns the assembled bytes", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      small = :crypto.strong_rand_bytes(5000)
      _ = upload_v2(user, vault, "small.bin", small)

      body = conn |> get("/api/attachments/small.bin") |> json_response(200)
      assert Base.decode64!(body["content_base64"]) == small
      assert body["size_bytes"] == 5000
    end

    # Over a real Bandit socket: once headers are out the status cannot
    # change, so a bad segment must cut the connection rather than let Bandit
    # finish the body (Plug.Test never shows what reaches the wire).
    test "a tampered segment cuts the connection after headers, with an error log", %{
      user: user,
      att: att
    } do
      {:ok, blob} = InMemory.get(att.storage_key)
      at = @seg + SegmentedCipher.overhead() + 100
      <<head::binary-size(at), b, rest::binary>> = blob
      :ok = InMemory.put(att.storage_key, <<head::binary, Bitwise.bxor(b, 1), rest::binary>>)

      {:ok, pid} =
        start_supervised(
          {Bandit, plug: EngramWeb.Endpoint, port: 0, ip: :loopback, startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      {:ok, key, _} = Engram.Accounts.create_api_key(user, "socket-key")

      log =
        capture_log(fn ->
          :ok =
            :gen_tcp.send(
              sock,
              "GET /api/attachments/videos/clip.mp4?raw=1 HTTP/1.1\r\nhost: localhost\r\n" <>
                "authorization: Bearer #{key}\r\n\r\n"
            )

          data = recv_until_closed(sock, [])
          [headers, body] = :binary.split(data, "\r\n\r\n")

          assert headers =~ "HTTP/1.1 200 OK"
          assert headers =~ ~r/content-length: #{@big}/i
          # Only the first, untampered segment made it out.
          assert byte_size(body) < @big
          assert byte_size(body) <= @seg
        end)

      assert log =~ "attachment segment unreadable"
      assert log =~ att.id
      refute log =~ "clip.mp4"
    end

    defp recv_until_closed(sock, acc) do
      case :gen_tcp.recv(sock, 0, 5_000) do
        {:ok, data} -> recv_until_closed(sock, [acc | data])
        {:error, :closed} -> IO.iodata_to_binary(acc)
      end
    end
  end
end
