defmodule Engram.Attachments.UploadsTest do
  # async: false: the RLS tests drop the connection role (connection-global),
  # and the Database-adapter test swaps the global :storage env.
  use Engram.DataCase, async: false

  import Engram.RlsCase

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

      assert {:error, :not_found} = Uploads.status(user, vault, up.id)
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
