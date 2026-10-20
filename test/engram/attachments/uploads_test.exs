defmodule Engram.Attachments.UploadsTest do
  # async: false: the RLS tests drop the connection role (connection-global),
  # and the Database-adapter test swaps the global :storage env.
  use Engram.DataCase, async: false

  import Engram.RlsCase
  import Mox

  alias Engram.Attachments
  alias Engram.Attachments.Attachment
  alias Engram.Attachments.SegmentedCipher
  alias Engram.Attachments.Upload
  alias Engram.Attachments.Uploads
  alias Engram.Crypto
  alias Engram.Storage.InMemory

  @mib 1024 * 1024
  @part 8 * @mib

  setup do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp allow_big_files(user) do
    insert(:user_limit_override, user: user, key: "max_file_bytes", value: %{"v" => 100 * @mib})
  end

  defp start!(user, vault, path, size) do
    {:ok, %Upload{} = up} =
      Uploads.start(user, vault, %{path: path, size_bytes: size, mtime: 1.0})

    up
  end

  defp parts(bytes), do: for(<<p::binary-size(@part) <- bytes>>, do: p) ++ [tail(bytes)]

  defp tail(bytes),
    do: binary_part(bytes, div(byte_size(bytes), @part) * @part, rem(byte_size(bytes), @part))

  defp put_all(user, vault, up, bytes) do
    bytes
    |> parts()
    |> Enum.with_index(1)
    |> Enum.each(fn {p, n} ->
      assert {:ok, %{part: ^n}} = Uploads.put_part(user, vault, up.id, n, p)
    end)
  end

  describe "start/3 refusals" do
    test "a blocked extension", %{user: user, vault: vault} do
      assert {:error, {:extension_not_allowed, ".exe"}} =
               Uploads.start(user, vault, %{path: "a.exe", size_bytes: 10, mtime: 1.0})
    end

    test "a declared size over max_file_bytes", %{user: user, vault: vault} do
      assert {:error, {:too_large, 10_485_760}} =
               Uploads.start(user, vault, %{path: "big.mp4", size_bytes: 10_485_761, mtime: 1.0})
    end

    test "a declared size over the storage quota", %{user: user, vault: vault} do
      insert(:user_limit_override, user: user, key: "attachment_bytes_cap", value: %{"v" => 1000})

      assert {:error, {:storage_cap_reached, 0, 1000}} =
               Uploads.start(user, vault, %{path: "a.png", size_bytes: 2000, mtime: 1.0})
    end

    test "a storage backend without multipart", %{user: user, vault: vault} do
      prev = Application.get_env(:engram, :storage)
      Application.put_env(:engram, :storage, Engram.Storage.Database)
      on_exit(fn -> Application.put_env(:engram, :storage, prev) end)

      assert {:error, :multipart_unsupported} =
               Uploads.start(user, vault, %{path: "a.png", size_bytes: 10, mtime: 1.0})
    end

    test "refusals leave no session row", %{user: user, vault: vault} do
      Uploads.start(user, vault, %{path: "a.exe", size_bytes: 10, mtime: 1.0})
      assert Repo.aggregate(Upload, :count, skip_tenant_check: true) == 0
    end
  end

  describe "put_part/5" do
    setup %{user: user, vault: vault} do
      allow_big_files(user)
      # 20 MiB: parts 8, 8, 4 MiB.
      %{up: start!(user, vault, "videos/clip.mp4", 20 * @mib)}
    end

    test "advertises the part layout", %{up: up} do
      assert up.part_size == @part
      assert up.part_count == 3
    end

    test "refuses a part number outside 1..part_count", %{user: user, vault: vault, up: up} do
      assert {:error, :bad_part_number} = Uploads.put_part(user, vault, up.id, 0, "x")
      assert {:error, :bad_part_number} = Uploads.put_part(user, vault, up.id, 4, "x")
    end

    test "refuses a part of the wrong size", %{user: user, vault: vault, up: up} do
      assert {:error, :bad_part_size} = Uploads.put_part(user, vault, up.id, 1, "short")

      assert {:error, :bad_part_size} =
               Uploads.put_part(user, vault, up.id, 1, :binary.copy("x", @part + 1))

      # The final part must be exactly the remainder (4 MiB), not a full part.
      assert {:error, :bad_part_size} =
               Uploads.put_part(user, vault, up.id, 3, :binary.copy("x", @part))

      assert {:ok, %{done: []}} = Uploads.status(user, vault, up.id)
    end

    test "an unknown session", %{user: user, vault: vault} do
      assert {:error, :not_found} = Uploads.put_part(user, vault, Ecto.UUID.generate(), 1, "x")
    end
  end

  describe "complete/3" do
    setup %{user: user} do
      allow_big_files(user)
      %{bytes: :crypto.strong_rand_bytes(20 * @mib)}
    end

    test "commits a live v2 attachment whose segments decrypt to the upload", %{
      user: user,
      vault: vault,
      bytes: bytes
    } do
      up = start!(user, vault, "videos/clip.mp4", byte_size(bytes))
      put_all(user, vault, up, bytes)
      # Re-PUT of a part replaces it.
      assert {:ok, %{part: 2}} = Uploads.put_part(user, vault, up.id, 2, Enum.at(parts(bytes), 1))

      assert {:ok, %{done: [1, 2, 3], part_count: 3, part_size: @part}} =
               Uploads.status(user, vault, up.id)

      assert {:ok, %Attachment{} = att} = Uploads.complete(user, vault, up.id)

      assert att.encryption_version == 2
      assert att.size_bytes == byte_size(bytes)
      assert att.segment_count == 3
      assert att.segment_size == @part
      assert att.path == "videos/clip.mp4"
      assert is_nil(att.content_nonce)

      {:ok, content_key} = Crypto.dek_content_hash_key(user)
      assert att.content_hash == Crypto.hmac_content_hash(content_key, bytes)

      assert decrypt_stored(user, att) == bytes
      refute String.contains?(stored_blob(att), binary_part(bytes, 0, 64))

      assert {:ok, %{completed: true, done: [1, 2, 3]}} = Uploads.status(user, vault, up.id)
      assert {:ok, [%{path: "videos/clip.mp4"}]} = Attachments.list_attachments(user, vault)
    end

    test "names the missing parts", %{user: user, vault: vault, bytes: bytes} do
      up = start!(user, vault, "videos/clip.mp4", byte_size(bytes))
      [p1, p2, _] = parts(bytes)
      {:ok, _} = Uploads.put_part(user, vault, up.id, 1, p1)
      {:ok, _} = Uploads.put_part(user, vault, up.id, 2, p2)

      assert {:error, {:missing_parts, [3]}} = Uploads.complete(user, vault, up.id)
      assert {:ok, %{done: [1, 2]}} = Uploads.status(user, vault, up.id)
    end

    test "re-checks the quota against live usage and drops the blob", %{
      user: user,
      vault: vault,
      bytes: bytes
    } do
      insert(:user_limit_override,
        user: user,
        key: "attachment_bytes_cap",
        value: %{"v" => byte_size(bytes) + 10}
      )

      up = start!(user, vault, "videos/clip.mp4", byte_size(bytes))
      put_all(user, vault, up, bytes)

      # Another upload lands first and takes the room.
      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{path: "other.png", content: "0123456789ab"})

      assert {:error, {:storage_cap_reached, 12, _}} = Uploads.complete(user, vault, up.id)
      refute InMemory.exists?(up.storage_key)
      assert {:error, :not_found} = Uploads.status(user, vault, up.id)
    end

    test "a v1 upload that took the path first: one live row, key bound to its id", %{
      user: user,
      vault: vault,
      bytes: bytes
    } do
      up = start!(user, vault, "videos/clip.mp4", byte_size(bytes))
      put_all(user, vault, up, bytes)

      {:ok, v1} =
        Attachments.upsert_attachment(user, vault, %{path: "videos/clip.mp4", content: "small v1"})

      refute v1.id == up.attachment_id

      assert {:ok, att} = Uploads.complete(user, vault, up.id)
      assert att.id == v1.id
      assert decrypt_stored(user, att) == bytes
      refute InMemory.exists?(v1.storage_key)
      assert Repo.aggregate(Attachment, :count, skip_tenant_check: true) == 1
    end
  end

  describe "complete/3 recovery and races" do
    setup %{user: user, vault: vault} do
      allow_big_files(user)
      bytes = :crypto.strong_rand_bytes(20 * @mib)
      up = start!(user, vault, "videos/clip.mp4", byte_size(bytes))
      put_all(user, vault, up, bytes)
      %{bytes: bytes, up: up}
    end

    # InMemory storage whose first ranged read fails (a transient S3 error
    # after the multipart upload was already assembled).
    defp fail_first_get_range do
      prev = Application.get_env(:engram, :storage)
      Application.put_env(:engram, :storage, Engram.MockStorage)
      on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
      stub_with(Engram.MockStorage, InMemory)
      failed = :counters.new(1, [])

      stub(Engram.MockStorage, :get_range, fn key, offset, len ->
        if :counters.get(failed, 1) == 0 do
          :counters.add(failed, 1, 1)
          {:error, :timeout}
        else
          InMemory.get_range(key, offset, len)
        end
      end)
    end

    test "resumes after a failure that follows assembly", %{
      user: user,
      vault: vault,
      bytes: bytes,
      up: up
    } do
      fail_first_get_range()

      assert {:error, {:storage, :timeout}} = Uploads.complete(user, vault, up.id)
      assert {:ok, att} = Uploads.complete(user, vault, up.id)
      assert decrypt_stored(user, att) == bytes
    end

    test "a duplicate complete with a stale session commits nothing", %{
      user: user,
      vault: vault,
      up: up
    } do
      # Reach the state a second concurrent caller holds: a session struct
      # fetched after assembly, used after the first caller committed.
      fail_first_get_range()
      {:error, _} = Uploads.complete(user, vault, up.id)
      stale = Repo.get!(Upload, up.id, skip_tenant_check: true)
      refute is_nil(stale.assembled_at)

      {:ok, att} = Uploads.complete(user, vault, up.id)

      assert {:error, :not_found} = Uploads.complete_session(user, vault, stale)

      live = Repo.get!(Attachment, att.id, skip_tenant_check: true)
      assert live.version == att.version
      assert live.seq == att.seq
      assert InMemory.exists?(att.storage_key)
    end

    # The duplicate a client sends after its first complete timed out can
    # arrive while that first one is still running. The loser rolls back,
    # then answers with what the winner committed rather than 404.
    test "a complete that loses the race to a concurrent one returns its attachment", %{
      user: user,
      vault: vault,
      up: up,
      bytes: bytes
    } do
      prev = Application.get_env(:engram, :storage)
      Application.put_env(:engram, :storage, Engram.MockStorage)
      on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
      stub_with(Engram.MockStorage, InMemory)
      raced = :counters.new(1, [])
      parent = self()

      # The loser is mid read-back when the winner commits.
      stub(Engram.MockStorage, :get_range, fn key, offset, len ->
        if :counters.get(raced, 1) == 0 do
          :counters.add(raced, 1, 1)
          send(parent, {:winner, Uploads.complete(user, vault, up.id)})
        end

        InMemory.get_range(key, offset, len)
      end)

      assert {:ok, loser} = Uploads.complete(user, vault, up.id)
      assert_received {:winner, {:ok, winner}}
      assert loser.id == winner.id
      assert loser.version == winner.version
      assert decrypt_stored(user, loser) == bytes
    end

    test "a single-request upload over a chunked one replaces it cleanly", %{
      user: user,
      vault: vault,
      up: up
    } do
      {:ok, v2} = Uploads.complete(user, vault, up.id)

      {:ok, v1} =
        Attachments.upsert_attachment(user, vault, %{path: "videos/clip.mp4", content: "v1 bytes"})

      assert v1.id == v2.id
      row = Repo.get!(Attachment, v1.id, skip_tenant_check: true)
      assert row.encryption_version == 1
      assert is_nil(row.wrapped_file_key)
      assert is_nil(row.file_key_nonce)
      assert is_nil(row.upload_id)
      assert is_nil(row.segment_size)
      assert is_nil(row.segment_count)

      refute row.storage_key == v2.storage_key
      assert InMemory.exists?(row.storage_key)
      refute InMemory.exists?(v2.storage_key)

      assert {:ok, %{content: "v1 bytes"}} =
               Attachments.get_attachment(user, vault, "videos/clip.mp4")
    end

    test "a single-request upload racing a chunked complete keeps its blob", %{
      user: user,
      vault: vault
    } do
      # The live v1 row the chunked upload claims at start.
      {:ok, old} =
        Attachments.upsert_attachment(user, vault, %{path: "doc.png", content: "old v1"})

      bytes = :crypto.strong_rand_bytes(10)
      up = start!(user, vault, "doc.png", byte_size(bytes))
      assert up.attachment_id == old.id
      put_all(user, vault, up, bytes)

      prev = Application.get_env(:engram, :storage)
      Application.put_env(:engram, :storage, Engram.MockStorage)
      on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
      stub_with(Engram.MockStorage, InMemory)
      raced = :counters.new(1, [])

      # The v1 PUT lands before its lock; the chunked complete commits in that
      # window and releases the row's previous blob. The v1 write's own key
      # is fresh, so that cleanup cannot reach it.
      stub(Engram.MockStorage, :put, fn key, bin, opts ->
        :ok = InMemory.put(key, bin, opts)

        if :counters.get(raced, 1) == 0 do
          :counters.add(raced, 1, 1)
          assert {:ok, _} = Uploads.complete(user, vault, up.id)
          refute InMemory.exists?(old.storage_key)
          assert InMemory.exists?(key)
        end

        :ok
      end)

      {:ok, _} = Attachments.upsert_attachment(user, vault, %{path: "doc.png", content: "new v1"})

      assert {:ok, %{content: "new v1", encryption_version: 1}} =
               Attachments.get_attachment(user, vault, "doc.png")

      refute InMemory.exists?(up.storage_key)
    end

    # Not a true two-completes race: under the sandbox both would share one
    # connection, where an advisory lock is re-entrant and blocks nothing. A
    # second connection holding the per-user quota lock proves complete
    # serializes on it.
    test "complete waits on the per-user quota lock", %{user: user, vault: vault, up: up} do
      parent = self()

      holder =
        spawn_link(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

          Repo.transaction(fn ->
            Repo.advisory_lock!(Attachments.quota_lock_id(user.id))
            send(parent, :held)
            receive do: (:release -> :ok)
          end)

          Ecto.Adapters.SQL.Sandbox.checkin(Repo)
          send(parent, :released)
        end)

      assert_receive :held, 2_000
      completer = Task.async(fn -> Uploads.complete(user, vault, up.id) end)

      refute Task.yield(completer, 300), "complete did not wait for the user quota lock"

      send(holder, :release)
      assert_receive :released, 2_000
      assert {:ok, %Attachment{}} = Task.await(completer, 10_000)
    end
  end

  # A write that commits after DEK rotation has swept past it is wrapped under
  # the retiring key and becomes unreadable once the rotation finishes.
  # The gate above only sees a rotation that is still running. One that
  # acquires, sweeps and releases while a writer holds a DEK it read earlier
  # leaves the lock clear, so the write must be refused on the DEK version.
  describe "a DEK rotation that completes inside a write" do
    setup do
      bypass = Bypass.open()
      Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
      on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

      Bypass.stub(bypass, "POST", "/collections/engram_notes/points/scroll", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"result" => %{"points" => [], "next_page_offset" => nil}})
        )
      end)

      prev = Application.get_env(:engram, :storage)
      Application.put_env(:engram, :storage, Engram.MockStorage)
      on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
      stub_with(Engram.MockStorage, InMemory)
      # Rotation decrypts every vault name the user owns; the bare factory
      # vault's is not real ciphertext, so this describe uses its own user.
      {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
      %{user: user, vault: Engram.Fixtures.insert_vault!(user, "RotationWindow")}
    end

    # Runs a full rotation the first time storage call `fun_name` is made,
    # then passes the call through to InMemory.
    defp rotate_during(user, fun_name, arity) do
      ran = :counters.new(1, [])

      hook = fn args ->
        if :counters.get(ran, 1) == 0 do
          :counters.add(ran, 1, 1)
          assert :ok = Engram.Crypto.UserDekRotation.rotate_user(user.id)
        end

        apply(InMemory, fun_name, args)
      end

      fun =
        case arity do
          1 -> fn a -> hook.([a]) end
          3 -> fn a, b, c -> hook.([a, b, c]) end
        end

      stub(Engram.MockStorage, fun_name, fun)
    end

    defp all(schema, user) do
      import Ecto.Query, only: [from: 2]
      Engram.Repo.all(from(r in schema, where: r.user_id == ^user.id), skip_tenant_check: true)
    end

    test "a single-request write is refused and stores nothing", %{user: user, vault: vault} do
      rotate_during(user, :put, 3)

      assert {:error, :rotation_in_progress} =
               Attachments.upsert_attachment(user, vault, %{path: "doc.png", content: "v1"})

      assert all(Attachment, user) == []

      refute Enum.any?(:ets.tab2list(:engram_test_storage_in_memory), fn {k, _} ->
               String.starts_with?(k, "#{user.id}/#{vault.id}/")
             end)
    end

    test "start is refused and opens no session", %{user: user, vault: vault} do
      rotate_during(user, :start_multipart, 1)

      assert {:error, :rotation_in_progress} =
               Uploads.start(user, vault, %{path: "a.png", size_bytes: 10, mtime: 1.0})

      assert all(Upload, user) == []
    end

    test "complete is refused; the retry on the rotated session succeeds", %{
      user: user,
      vault: vault
    } do
      bytes = :crypto.strong_rand_bytes(10)
      up = start!(user, vault, "a.png", 10)
      {:ok, _} = Uploads.put_part(user, vault, up.id, 1, bytes)
      rotate_during(user, :complete_multipart_upload, 3)

      assert {:error, :rotation_in_progress} = Uploads.complete(user, vault, up.id)
      assert all(Attachment, user) == []
      assert [_] = all(Upload, user)

      user = Crypto.fresh_user(user)
      assert {:ok, att} = Uploads.complete(user, vault, up.id)
      assert decrypt_stored(user, Engram.Repo.reload!(att, skip_tenant_check: true)) == bytes
    end
  end

  describe "while a DEK rotation holds the user" do
    defp set_rotation_lock(user, at) do
      import Ecto.Query, only: [from: 2]

      Engram.Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^user.id),
        [set: [dek_rotation_locked_at: at]],
        skip_tenant_check: true
      )

      # The auth path serves the user from the :user cache.
      Engram.Accounts.evict_user(user.id)
    end

    defp rows(schema, user) do
      import Ecto.Query, only: [from: 2]
      Engram.Repo.all(from(r in schema, where: r.user_id == ^user.id), skip_tenant_check: true)
    end

    test "start is refused and opens nothing", %{user: user, vault: vault} do
      set_rotation_lock(user, DateTime.utc_now(:second))

      assert {:error, :rotation_in_progress} =
               Uploads.start(user, vault, %{path: "a.png", size_bytes: 10, mtime: 1.0})

      assert rows(Upload, user) == []
    end

    # The top-of-start check passed; the rotation starts while storage opens
    # the multipart upload, before the session row is inserted.
    test "a rotation that starts mid-start is refused at the insert", %{
      user: user,
      vault: vault
    } do
      prev = Application.get_env(:engram, :storage)
      Application.put_env(:engram, :storage, Engram.MockStorage)
      on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
      stub_with(Engram.MockStorage, InMemory)

      stub(Engram.MockStorage, :start_multipart, fn key ->
        set_rotation_lock(user, DateTime.utc_now(:second))
        InMemory.start_multipart(key)
      end)

      assert {:error, :rotation_in_progress} =
               Uploads.start(user, vault, %{path: "a.png", size_bytes: 10, mtime: 1.0})

      assert rows(Upload, user) == []
    end

    test "put_part is refused and records nothing", %{user: user, vault: vault} do
      up = start!(user, vault, "a.png", 10)
      set_rotation_lock(user, DateTime.utc_now(:second))

      assert {:error, :rotation_in_progress} =
               Uploads.put_part(user, vault, up.id, 1, :binary.copy("x", 10))

      assert [%Upload{parts: parts}] = rows(Upload, user)
      assert parts == %{}
    end

    test "complete is refused, keeps the session, and succeeds once the lock clears", %{
      user: user,
      vault: vault
    } do
      up = start!(user, vault, "a.png", 10)
      bytes = :binary.copy("x", 10)
      {:ok, _} = Uploads.put_part(user, vault, up.id, 1, bytes)
      set_rotation_lock(user, DateTime.utc_now(:second))

      assert {:error, :rotation_in_progress} = Uploads.complete(user, vault, up.id)
      assert rows(Attachment, user) == []
      assert [_] = rows(Upload, user)

      set_rotation_lock(user, nil)
      assert {:ok, att} = Uploads.complete(user, vault, up.id)
      assert decrypt_stored(user, Engram.Repo.reload!(att, skip_tenant_check: true)) == bytes
    end

    test "a single-request upload is refused at the locked write", %{user: user, vault: vault} do
      set_rotation_lock(user, DateTime.utc_now(:second))

      assert {:error, :rotation_in_progress} =
               Attachments.upsert_attachment(user, vault, %{path: "doc.png", content: "v1"})

      assert rows(Attachment, user) == []

      set_rotation_lock(user, nil)

      assert {:ok, _} =
               Attachments.upsert_attachment(user, vault, %{path: "doc.png", content: "v1"})
    end
  end

  # A client whose complete timed out after the server committed retries it.
  # The session is kept, marked completed, so the retry gets the attachment.
  describe "a completed session" do
    setup %{user: user, vault: vault} do
      bytes = :crypto.strong_rand_bytes(10)
      up = start!(user, vault, "doc.png", byte_size(bytes))
      put_all(user, vault, up, bytes)
      {:ok, att} = Uploads.complete(user, vault, up.id)
      %{bytes: bytes, up: up, att: att}
    end

    test "a repeat complete returns the committed attachment", %{
      user: user,
      vault: vault,
      up: up,
      att: att
    } do
      assert {:ok, %Attachment{} = again} = Uploads.complete(user, vault, up.id)
      assert again.id == att.id
      assert again.path == "doc.png"
      assert again.version == att.version
      assert again.seq == att.seq
    end

    test "status reports completed", %{user: user, vault: vault, up: up} do
      assert {:ok, %{completed: true}} = Uploads.status(user, vault, up.id)
    end

    test "a repeat complete after a move returns the moved attachment", %{
      user: user,
      vault: vault,
      up: up,
      att: att
    } do
      {:ok, _} = Attachments.move_attachment(user, vault, "doc.png", "moved.png")
      assert {:ok, %{id: id, path: "moved.png"}} = Uploads.complete(user, vault, up.id)
      assert id == att.id
    end

    test "a repeat complete after the attachment was deleted is :not_found", %{
      user: user,
      vault: vault,
      up: up
    } do
      :ok = Attachments.delete_attachment(user, vault, "doc.png")
      assert {:error, :not_found} = Uploads.complete(user, vault, up.id)
    end

    test "a repeat complete after an overwrite is :not_found", %{
      user: user,
      vault: vault,
      up: up
    } do
      {:ok, _} = Attachments.upsert_attachment(user, vault, %{path: "doc.png", content: "newer"})
      assert {:error, :not_found} = Uploads.complete(user, vault, up.id)
    end

    test "put_part is refused", %{user: user, vault: vault, up: up, bytes: bytes} do
      assert {:error, :upload_completed} = Uploads.put_part(user, vault, up.id, 1, bytes)
    end

    test "abort touches neither storage nor the attachment", %{
      user: user,
      vault: vault,
      up: up,
      att: att,
      bytes: bytes
    } do
      assert :ok = Uploads.abort(user, vault, up.id)
      assert InMemory.exists?(att.storage_key)
      assert decrypt_stored(user, att) == bytes
      assert {:ok, %{completed: true}} = Uploads.status(user, vault, up.id)
    end

    test "a stale in-flight struct cannot commit it again", %{user: user, vault: vault, up: up} do
      stale = Repo.get!(Upload, up.id, skip_tenant_check: true)

      assert {:error, :not_found} =
               Uploads.complete_session(user, vault, %{stale | completed_at: nil})
    end
  end

  describe "abort/3" do
    test "drops the session", %{user: user, vault: vault} do
      up = start!(user, vault, "a.png", 10)
      assert :ok = Uploads.abort(user, vault, up.id)
      assert {:error, :not_found} = Uploads.status(user, vault, up.id)
      assert :ok = Uploads.abort(user, vault, up.id)
    end
  end

  describe "tenancy" do
    setup %{user: user, vault: vault} do
      %{up: start!(user, vault, "a.png", 10)}
    end

    test "another user's status is :not_found", %{vault: vault, up: up} do
      {:ok, other} = Crypto.ensure_user_dek(insert(:user))
      assert {:error, :not_found} = Uploads.status(other, vault, up.id)
      assert {:error, :not_found} = Uploads.put_part(other, vault, up.id, 1, "0123456789")
      assert {:error, :not_found} = Uploads.complete(other, vault, up.id)
    end

    # CONTROL (docs/context/rls-enforcement-testing-traps.md): without it a
    # green policy test is ambiguous between "scoped" and "role never dropped".
    test "control: engram_app with no tenant sees zero sessions", %{up: up} do
      assert {:returned, 0} = as_prod_role(fn -> count_session(up.id) end)
    end

    test "the policy hides a session from any tenant but its owner", %{user: user, up: up} do
      other = insert(:user)

      assert {:returned, 0} =
               as_prod_role(fn -> as_tenant(other.id, fn -> count_session(up.id) end) end)

      assert {:returned, 1} =
               as_prod_role(fn -> as_tenant(user.id, fn -> count_session(up.id) end) end)
    end
  end

  defp count_session(id),
    do: Repo.one(from(u in Upload, where: u.id == ^id, select: count()), skip_tenant_check: true)

  defp as_tenant(user_id, fun) do
    Repo.query!("SELECT set_config('app.current_tenant', $1, true)", [user_id])
    fun.()
  end

  defp stored_blob(att) do
    {:ok, blob} = InMemory.get(att.storage_key)
    blob
  end

  defp decrypt_stored(user, %Attachment{} = att) do
    {:ok, dek} = Crypto.get_dek(Crypto.fresh_user(user))
    {:ok, key} = SegmentedCipher.unwrap_key(att.wrapped_file_key, att.file_key_nonce, dek, att.id)
    sealed = att.segment_size + SegmentedCipher.overhead()
    blob = stored_blob(att)

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
end
