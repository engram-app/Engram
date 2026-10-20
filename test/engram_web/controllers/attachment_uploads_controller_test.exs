defmodule EngramWeb.AttachmentUploadsControllerTest do
  # async: false: other files swap the global :storage adapter.
  use EngramWeb.ConnCase, async: false

  import Ecto.Query

  alias Engram.Attachments
  alias Engram.Attachments.Attachment
  alias Engram.Attachments.SegmentedCipher
  alias Engram.Attachments.Upload
  alias Engram.Attachments.Uploads
  alias Engram.Crypto
  alias Engram.Repo
  alias Engram.Storage.InMemory

  @mib 1024 * 1024
  @part 8 * @mib

  setup %{conn: conn} do
    user = insert(:user)
    insert(:subscription, user: user, tier: "pro", status: "active")
    vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    lift_api_rps_cap!(user)
    insert(:user_limit_override, user: user, key: "max_file_bytes", value: %{"v" => 100 * @mib})
    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key}"), user: user, vault: vault}
  end

  defp start(conn, path, size) do
    post(conn, "/api/attachment-uploads", %{path: path, size_bytes: size, mtime: 1.0})
  end

  defp start!(conn, path, size), do: conn |> start(path, size) |> json_response(201)

  defp put_part(conn, id, n, bytes) do
    conn
    |> put_req_header("content-type", "application/octet-stream")
    |> put_req_header("content-length", Integer.to_string(byte_size(bytes)))
    |> put("/api/attachment-uploads/#{id}/parts/#{n}", bytes)
  end

  defp complete(conn, id), do: post(conn, "/api/attachment-uploads/#{id}/complete")

  defp used(user), do: elem(Attachments.storage_usage(user), 1).used_bytes

  defp session(id), do: Repo.get!(Upload, id, skip_tenant_check: true)

  defp decrypt_stored(user, %Attachment{} = att) do
    {:ok, dek} = Crypto.get_dek(Crypto.fresh_user(user))
    {:ok, key} = SegmentedCipher.unwrap_key(att.wrapped_file_key, att.file_key_nonce, dek, att.id)
    {:ok, blob} = InMemory.get(att.storage_key)
    sealed = att.segment_size + SegmentedCipher.overhead()

    for i <- 0..(att.segment_count - 1), into: <<>> do
      len = min(sealed, byte_size(blob) - i * sealed)

      {:ok, plain} =
        SegmentedCipher.open_segment(
          binary_part(blob, i * sealed, len),
          key,
          att.upload_id,
          i,
          att.segment_count
        )

      plain
    end
  end

  describe "happy path" do
    test "start, put parts, status, complete", %{conn: conn, user: user} do
      bytes = :crypto.strong_rand_bytes(@part + 10)

      assert %{"upload_id" => id, "part_size" => @part, "part_count" => 2} =
               start!(conn, "videos/clip.mp4", byte_size(bytes))

      <<p1::binary-size(@part), p2::binary>> = bytes
      assert %{"part" => 2} = conn |> put_part(id, 2, p2) |> json_response(200)

      assert %{"done" => [2], "part_count" => 2, "part_size" => @part} =
               conn |> get("/api/attachment-uploads/#{id}") |> json_response(200)

      assert %{"error" => "missing_parts", "missing" => [1]} =
               conn |> complete(id) |> json_response(409)

      assert %{"part" => 1} = conn |> put_part(id, 1, p1) |> json_response(200)

      assert %{"attachment" => att} = conn |> complete(id) |> json_response(200)
      assert att["path"] == "videos/clip.mp4"
      assert att["size_bytes"] == byte_size(bytes)
      assert att["mime_type"] == "video/mp4"
      assert is_binary(att["content_hash"])

      row = Repo.get!(Attachment, att["id"], skip_tenant_check: true)
      assert decrypt_stored(user, row) == bytes
      assert conn |> get("/api/attachment-uploads/#{id}") |> json_response(404)
    end

    test "DELETE drops the session, idempotently", %{conn: conn} do
      %{"upload_id" => id} = start!(conn, "a.png", 10)
      storage_key = session(id).storage_key

      assert conn |> delete("/api/attachment-uploads/#{id}") |> response(204)
      assert conn |> delete("/api/attachment-uploads/#{id}") |> response(204)
      assert conn |> get("/api/attachment-uploads/#{id}") |> json_response(404)
      refute InMemory.exists?(storage_key)
    end

    test "an unknown session is 404 on every route", %{conn: conn} do
      id = Ecto.UUID.generate()
      assert conn |> get("/api/attachment-uploads/#{id}") |> json_response(404)
      assert conn |> put_part(id, 1, "x") |> json_response(404)
      assert conn |> complete(id) |> json_response(404)
    end
  end

  # The parts protocol has its own prefix, so a vault file whose path looks
  # like an upload route is still an attachment.
  test "/api/attachments/uploads/<uuid> is the vault file at that path", %{conn: conn} do
    path = "uploads/#{Ecto.UUID.generate()}"

    conn
    |> post("/api/attachments", %{path: path, content_base64: Base.encode64("hi")})
    |> json_response(200)

    assert %{"path" => ^path} =
             conn |> get("/api/attachments/" <> path) |> json_response(200)

    assert %{"deleted" => true} =
             conn |> delete("/api/attachments/" <> path) |> json_response(200)

    assert conn |> get("/api/attachments/" <> path) |> json_response(404)
  end

  describe "start refusals" do
    test "a blocked extension is 415", %{conn: conn} do
      assert %{"error" => "extension_not_allowed", "extension" => ".exe"} =
               conn |> start("a.exe", 10) |> json_response(415)
    end

    test "a mime_type with header bytes is 422", %{conn: conn} do
      assert %{"error" => "invalid_mime_type"} =
               conn
               |> post("/api/attachment-uploads", %{
                 path: "a.png",
                 size_bytes: 10,
                 mime_type: "image/png\r\nx: y"
               })
               |> json_response(422)
    end

    test "over max_file_bytes is 402 file_too_large", %{conn: conn} do
      assert %{"reason" => "file_too_large"} =
               conn |> start("big.mp4", 100 * @mib + 1) |> json_response(402)
    end

    test "over the quota is 402 attachments_quota_exceeded", %{conn: conn, user: user} do
      insert(:user_limit_override, user: user, key: "attachment_bytes_cap", value: %{"v" => 100})

      assert %{"reason" => "attachments_quota_exceeded"} =
               conn |> start("a.png", 200) |> json_response(402)
    end

    test "a backend without multipart is 501", %{conn: conn} do
      prev = Application.get_env(:engram, :storage)
      Application.put_env(:engram, :storage, Engram.Storage.Database)
      on_exit(fn -> Application.put_env(:engram, :storage, prev) end)

      assert %{"error" => "multipart_unsupported"} =
               conn |> start("a.png", 10) |> json_response(501)
    end

    test "a text-only plan cannot start a non-text upload", %{conn: conn, user: user} do
      insert(:user_limit_override,
        user: user,
        key: "attachments_all_types",
        value: %{"v" => false},
        reason: "revoke for test",
        set_by: "test"
      )

      assert %{"reason" => "attachment_must_be_text"} =
               conn |> start("a.png", 10) |> json_response(402)
    end

    test "a missing size is 422", %{conn: conn} do
      assert conn |> post("/api/attachment-uploads", %{path: "a.png"}) |> json_response(422)
    end
  end

  # Review Focus 1.
  test "a v1 upload between start and complete: one live row, the v2 bytes win", %{
    conn: conn,
    user: user,
    vault: vault
  } do
    bytes = :crypto.strong_rand_bytes(1000)
    %{"upload_id" => id} = start!(conn, "photos/a.png", byte_size(bytes))
    assert conn |> put_part(id, 1, bytes) |> json_response(200)

    v1 =
      conn
      |> post("/api/attachments", %{path: "photos/a.png", content_base64: Base.encode64("v1")})
      |> json_response(200)

    {:ok, %{storage_key: v1_key}} = Attachments.get_attachment(user, vault, "photos/a.png")

    assert %{"attachment" => att} = conn |> complete(id) |> json_response(200)
    assert att["id"] == v1["attachment"]["id"]

    hmac = session_hmac(user, "photos/a.png")

    assert [row] =
             Repo.all(
               from(a in Attachment, where: a.path_hmac == ^hmac and is_nil(a.deleted_at)),
               skip_tenant_check: true
             )

    assert row.id == att["id"]
    assert decrypt_stored(user, row) == bytes
    assert conn |> get("/api/attachments/photos/a.png?raw=1") |> response(200) == bytes
    refute InMemory.exists?(v1_key)
  end

  defp session_hmac(user, path) do
    {:ok, filter_key} = Crypto.dek_filter_key(Crypto.fresh_user(user))
    Crypto.hmac_field(filter_key, path)
  end

  # Review Focus 2.
  test "a part re-PUT after its ETag was lost still completes", %{conn: conn, user: user} do
    bytes = :crypto.strong_rand_bytes(@part + 10)
    <<p1::binary-size(@part), p2::binary>> = bytes
    %{"upload_id" => id} = start!(conn, "videos/clip.mp4", byte_size(bytes))

    assert conn |> put_part(id, 1, p1) |> json_response(200)
    assert conn |> put_part(id, 2, p2) |> json_response(200)

    # S3 accepted part 2 but the DB never recorded it.
    {1, _} =
      Repo.update_all(
        from(u in Upload, where: u.id == ^id, update: [set: [parts: fragment("parts - '2'")]]),
        [],
        skip_tenant_check: true
      )

    assert %{"done" => [1]} = conn |> get("/api/attachment-uploads/#{id}") |> json_response(200)
    assert conn |> put_part(id, 2, p2) |> json_response(200)
    assert %{"attachment" => att} = conn |> complete(id) |> json_response(200)

    row = Repo.get!(Attachment, att["id"], skip_tenant_check: true)
    assert decrypt_stored(user, row) == bytes
  end

  # Review Focus 3.
  describe "declared size lies" do
    setup %{conn: conn, user: user} do
      before = used(user)
      %{"upload_id" => id} = start!(conn, "videos/clip.mp4", 10 * @mib)
      %{id: id, before: before}
    end

    test "a part past part_count is 422 bad_part_number", %{conn: conn, id: id} do
      assert %{"error" => "bad_part_number"} =
               conn |> put_part(id, 3, "x") |> json_response(422)

      assert %{"error" => "bad_part_number"} =
               conn |> put_part(id, "two", "x") |> json_response(422)
    end

    test "a short non-final part is 422 bad_part_size", %{conn: conn, id: id} do
      assert %{"error" => "bad_part_size"} =
               conn |> put_part(id, 1, "short") |> json_response(422)
    end

    test "a part over part_size is 422 bad_part_size, unread", %{conn: conn, id: id} do
      assert %{"error" => "bad_part_size"} =
               conn |> put_part(id, 1, :binary.copy("x", @part + 1)) |> json_response(422)
    end

    test "nothing is stored and no quota is consumed", %{
      conn: conn,
      user: user,
      id: id,
      before: before
    } do
      conn |> put_part(id, 3, "x") |> json_response(422)
      conn |> put_part(id, 1, "short") |> json_response(422)

      assert %{"done" => []} = conn |> get("/api/attachment-uploads/#{id}") |> json_response(200)
      assert used(user) == before
    end
  end

  # Review Focus 4. Sequential: the concurrent case is Uploads' lock test.
  test "two sessions that fit alone but not together: the second complete is 402", %{
    conn: conn,
    user: user
  } do
    insert(:user_limit_override, user: user, key: "attachment_bytes_cap", value: %{"v" => 1000})
    a = :crypto.strong_rand_bytes(600)
    b = :crypto.strong_rand_bytes(600)

    %{"upload_id" => id_a} = start!(conn, "a.png", 600)
    %{"upload_id" => id_b} = start!(conn, "b.png", 600)
    assert conn |> put_part(id_a, 1, a) |> json_response(200)
    assert conn |> put_part(id_b, 1, b) |> json_response(200)
    key_b = session(id_b).storage_key

    assert conn |> complete(id_a) |> json_response(200)

    assert %{"reason" => "attachments_quota_exceeded"} =
             conn |> complete(id_b) |> json_response(402)

    refute InMemory.exists?(key_b)
    assert conn |> get("/api/attachment-uploads/#{id_b}") |> json_response(404)
    assert used(user) == 600
  end

  # Review fix: tenant scoping at the HTTP layer. Every route answers 404 for
  # a session the caller's user+vault does not own, and a foreign DELETE
  # drops nothing.
  describe "foreign sessions" do
    setup %{user: user, vault: vault} do
      bytes = :crypto.strong_rand_bytes(100)
      {:ok, up} = Uploads.start(user, vault, %{path: "a.png", size_bytes: 100, mtime: 1.0})
      %{bytes: bytes, up: up}
    end

    defp assert_all_404(conn, id, bytes) do
      assert conn |> get("/api/attachment-uploads/#{id}") |> json_response(404)
      assert conn |> put_part(id, 1, bytes) |> json_response(404)
      assert conn |> complete(id) |> json_response(404)
      assert conn |> delete("/api/attachment-uploads/#{id}") |> response(204)
    end

    defp assert_owner_completes(conn, up, bytes) do
      assert %{"done" => []} =
               conn |> get("/api/attachment-uploads/#{up.id}") |> json_response(200)

      assert conn |> put_part(up.id, 1, bytes) |> json_response(200)
      assert conn |> complete(up.id) |> json_response(200)
    end

    test "another user's upload id is 404 everywhere", %{conn: conn, up: up, bytes: bytes} do
      other = insert(:user)
      insert(:subscription, user: other, tier: "pro", status: "active")
      insert(:vault, user: other, is_default: true)
      {:ok, other_key, _} = Engram.Accounts.create_api_key(other, "other-key")
      lift_api_rps_cap!(other)
      other_conn = put_req_header(build_conn(), "authorization", "Bearer #{other_key}")

      assert_all_404(other_conn, up.id, bytes)
      assert_owner_completes(conn, up, bytes)
    end

    test "the same user's upload id under another vault is 404 everywhere", %{
      conn: conn,
      user: user,
      up: up,
      bytes: bytes
    } do
      other_vault = insert(:vault, user: user)

      assert_all_404(put_req_header(conn, "x-vault-id", other_vault.id), up.id, bytes)
      assert_owner_completes(conn, up, bytes)
    end
  end

  describe "while a DEK rotation holds the user" do
    import Mox

    defp set_rotation_lock(user, at) do
      Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^user.id),
        [set: [dek_rotation_locked_at: at]],
        skip_tenant_check: true
      )

      # The auth path serves the user from the :user cache.
      Engram.Accounts.evict_user(user.id)
    end

    defp rows(schema, user),
      do: Repo.all(from(r in schema, where: r.user_id == ^user.id), skip_tenant_check: true)

    defp assert_rotating(resp) do
      assert %{"error" => "rotation_in_progress"} = json_response(resp, 503)
      assert get_resp_header(resp, "retry-after") == ["60"]
    end

    test "start, put_part and complete are 503 and write nothing; all succeed once cleared", %{
      conn: conn,
      user: user
    } do
      bytes = :crypto.strong_rand_bytes(100)
      %{"upload_id" => id} = start!(conn, "a.png", byte_size(bytes))
      set_rotation_lock(user, DateTime.utc_now(:second))

      assert_rotating(start(conn, "b.png", 10))
      assert_rotating(put_part(conn, id, 1, bytes))
      assert_rotating(complete(conn, id))
      assert [%Upload{parts: parts}] = rows(Upload, user)
      assert parts == %{}
      assert rows(Attachment, user) == []

      set_rotation_lock(user, nil)
      assert conn |> put_part(id, 1, bytes) |> json_response(200)
      assert %{"attachment" => _} = conn |> complete(id) |> json_response(200)
      assert conn |> start("b.png", 10) |> json_response(201)
    end

    # A rotation that already finished (lock clear, DEK version moved)
    # between the DEK read and the write.
    test "a rotation that completes mid-start or mid-complete is 503", %{
      conn: conn,
      user: user
    } do
      bump = fn ->
        Repo.update_all(
          from(u in Engram.Accounts.User, where: u.id == ^user.id),
          [inc: [dek_version: 1]],
          skip_tenant_check: true
        )
      end

      bytes = :crypto.strong_rand_bytes(100)
      %{"upload_id" => id} = start!(conn, "a.png", byte_size(bytes))
      assert conn |> put_part(id, 1, bytes) |> json_response(200)

      prev = Application.get_env(:engram, :storage)
      Application.put_env(:engram, :storage, Engram.MockStorage)
      on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
      stub_with(Engram.MockStorage, InMemory)

      stub(Engram.MockStorage, :start_multipart, fn key ->
        bump.()
        InMemory.start_multipart(key)
      end)

      stub(Engram.MockStorage, :complete_multipart_upload, fn key, s3_id, parts ->
        bump.()
        InMemory.complete_multipart_upload(key, s3_id, parts)
      end)

      assert_rotating(start(conn, "b.png", 10))
      assert_rotating(complete(conn, id))
      assert [_] = rows(Upload, user)
      assert rows(Attachment, user) == []
    end

    # The request plug saw no lock; the rotation starts while the parts are
    # assembled, before the locked row write.
    test "a rotation that starts mid-complete is refused at the row write", %{
      conn: conn,
      user: user
    } do
      bytes = :crypto.strong_rand_bytes(100)
      %{"upload_id" => id} = start!(conn, "a.png", byte_size(bytes))
      assert conn |> put_part(id, 1, bytes) |> json_response(200)

      prev = Application.get_env(:engram, :storage)
      Application.put_env(:engram, :storage, Engram.MockStorage)
      on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
      stub_with(Engram.MockStorage, InMemory)

      stub(Engram.MockStorage, :complete_multipart_upload, fn key, s3_id, parts ->
        set_rotation_lock(user, DateTime.utc_now(:second))
        InMemory.complete_multipart_upload(key, s3_id, parts)
      end)

      assert_rotating(complete(conn, id))
      assert rows(Attachment, user) == []
      assert [_] = rows(Upload, user)
    end
  end

  # Over a real Bandit socket: Plug.Test never reaches Bandit's body state,
  # which is what a refusal on a stale (pre-read) conn corrupts.
  describe "part bodies over HTTP/1" do
    @read_timeout 500

    setup %{user: user, vault: vault} do
      Application.put_env(:engram, :body_read_timeout, @read_timeout)
      on_exit(fn -> Application.delete_env(:engram, :body_read_timeout) end)

      {:ok, pid} =
        start_supervised(
          {Bandit, plug: EngramWeb.Endpoint, port: 0, ip: :loopback, startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      on_exit(fn -> :gen_tcp.close(sock) end)
      {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "socket-key")
      {:ok, up} = Uploads.start(user, vault, %{path: "v.mp4", size_bytes: 20 * @mib, mtime: 1.0})
      %{sock: sock, key: api_key, up: up}
    end

    defp head(method, path, key, extra),
      do:
        "#{method} #{path} HTTP/1.1\r\nhost: localhost\r\nauthorization: Bearer #{key}\r\n" <>
          extra <> "\r\n"

    defp recv_response(sock) do
      {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
      [status | _] = String.split(data, "\r\n")
      {status, data}
    end

    test "an over-size chunked part is 422 and the connection stays usable", %{
      sock: sock,
      key: key,
      up: up
    } do
      chunk = :binary.copy("x", @mib)

      :ok =
        :gen_tcp.send(sock, [
          head(
            "PUT",
            "/api/attachment-uploads/#{up.id}/parts/1",
            key,
            "content-type: application/octet-stream\r\ntransfer-encoding: chunked\r\n"
          ),
          for(_ <- 1..9, do: ["100000\r\n", chunk, "\r\n"]),
          "0\r\n\r\n"
        ])

      {status, data} = recv_response(sock)
      assert status == "HTTP/1.1 422 Unprocessable Content", data
      assert data =~ "bad_part_size"
      refute data =~ ~r/connection: close/i

      # Same keep-alive socket: the rest of the body was drained, not parsed
      # as the next request.
      :ok = :gen_tcp.send(sock, head("GET", "/api/attachment-uploads/#{up.id}", key, ""))
      {status, data} = recv_response(sock)
      assert status == "HTTP/1.1 200 OK", data
    end

    test "an unknown upload id is 404 before the body is read", %{sock: sock, key: key} do
      # Headers only: a server that reads the body first stalls into a 408.
      :ok =
        :gen_tcp.send(
          sock,
          head(
            "PUT",
            "/api/attachment-uploads/#{Ecto.UUID.generate()}/parts/1",
            key,
            "content-type: application/octet-stream\r\ncontent-length: 1000\r\n"
          )
        )

      {status, data} = recv_response(sock)
      assert status == "HTTP/1.1 404 Not Found", data
    end
  end
end
