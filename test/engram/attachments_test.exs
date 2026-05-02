defmodule Engram.AttachmentsTest do
  use Engram.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Mox

  alias Engram.Attachments
  alias Engram.Attachments.Attachment

  @path "photos/test.png"
  @valid_content Base.encode64("test image content")

  setup :verify_on_exit!

  setup do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)

    user = insert(:user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  describe "upsert_attachment/3" do
    test "creates attachment with vault_id scoped correctly", %{user: user, vault: vault} do
      expect(Engram.MockStorage, :put, fn _key, _binary, _opts -> :ok end)

      assert {:ok, att} =
               Attachments.upsert_attachment(user, vault, %{
                 "path" => @path,
                 "content_base64" => @valid_content
               })

      assert att.path == @path
      assert att.user_id == user.id
      assert att.vault_id == vault.id
      assert att.size_bytes == byte_size("test image content")
    end

    test "rejects attachment over max size", %{user: user, vault: vault} do
      oversized = Base.encode64(:binary.copy("x", 6 * 1024 * 1024))

      assert {:error, :too_large} =
               Attachments.upsert_attachment(user, vault, %{
                 "path" => @path,
                 "content_base64" => oversized
               })
    end

    test "returns error for invalid base64 content", %{user: user, vault: vault} do
      assert {:error, :invalid_base64} =
               Attachments.upsert_attachment(user, vault, %{
                 "path" => @path,
                 "content_base64" => "not valid base64!!!"
               })
    end

    test "returns error when content_base64 is missing", %{user: user, vault: vault} do
      assert {:error, :missing_content} =
               Attachments.upsert_attachment(user, vault, %{"path" => @path})
    end

    test "updates existing attachment at same path", %{user: user, vault: vault} do
      expect(Engram.MockStorage, :put, 2, fn _key, _binary, _opts -> :ok end)

      {:ok, v1} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => @path,
          "content_base64" => Base.encode64("original content")
        })

      {:ok, v2} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => @path,
          "content_base64" => Base.encode64("updated content")
        })

      # Same DB row id — it's an update, not a new insert
      assert v1.id == v2.id
      assert v2.size_bytes == byte_size("updated content")
    end

    test "vault isolation — attachment in vault A not visible from vault B", %{user: user} do
      vault_a = insert(:vault, user: user)
      vault_b = insert(:vault, user: user)

      expect(Engram.MockStorage, :put, fn _key, _binary, _opts -> :ok end)

      {:ok, _att} =
        Attachments.upsert_attachment(user, vault_a, %{
          "path" => @path,
          "content_base64" => @valid_content
        })

      # vault_b has no attachment at this path — MockStorage get would only be called if found
      assert {:ok, nil} = Attachments.get_attachment(user, vault_b, @path)
    end
  end

  describe "changeset validations" do
    setup %{user: user, vault: vault} do
      base = %{
        path: "x.png",
        content_hash: "abc",
        mime_type: "image/png",
        size_bytes: 10,
        user_id: user.id,
        vault_id: vault.id,
        encryption_version: 1,
        content_nonce: :crypto.strong_rand_bytes(12)
      }

      %{base: base}
    end

    test "rejects encryption_version other than 1", %{base: base} do
      changeset = Attachment.changeset(%Attachment{}, %{base | encryption_version: 0})
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).encryption_version
    end

    test "requires content_nonce", %{base: base} do
      changeset = Attachment.changeset(%Attachment{}, %{base | content_nonce: nil})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).content_nonce
    end
  end

  describe "encrypted S3 storage path" do
    setup do
      Mox.stub_with(Engram.MockStorage, Engram.Storage.InMemory)
      :ok
    end

    test "encrypts attachment content before put" do
      user = insert(:user) |> Engram.Repo.reload!()
      vault = insert(:vault, user: user)
      plaintext = "secret bytes"
      b64 = Base.encode64(plaintext)

      test_pid = self()

      Mox.expect(Engram.MockStorage, :put, fn _key, bytes, _opts ->
        send(test_pid, {:put_bytes, bytes})
        :ok
      end)

      {:ok, _att} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "secret.bin",
          "content_base64" => b64,
          "mtime" => 0.0
        })

      assert_receive {:put_bytes, stored}, 500
      refute stored == plaintext
      # AES-GCM ciphertext: plaintext bytes + 16-byte authentication tag
      assert byte_size(stored) == byte_size(plaintext) + 16
    end

    test "round-trips encrypted attachment via get_attachment" do
      user = insert(:user) |> Engram.Repo.reload!()
      vault = insert(:vault, user: user)
      plaintext = "round trip me"
      b64 = Base.encode64(plaintext)

      {:ok, _att} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "rt.bin",
          "content_base64" => b64,
          "mtime" => 0.0
        })

      {:ok, fetched} = Attachments.get_attachment(user, vault, "rt.bin")
      assert fetched.content == plaintext
      assert fetched.encryption_version == 1
      assert is_binary(fetched.content_nonce)
    end

    test "returns {:error, :decrypt_failed} when stored nonce is corrupted" do
      user = insert(:user) |> Engram.Repo.reload!()
      vault = insert(:vault, user: user)

      {:ok, _real} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "ghost.bin",
          "content_base64" => Base.encode64("real plaintext"),
          "mtime" => 0.0
        })

      {:ok, _} =
        Engram.Repo.with_tenant(user.id, fn ->
          from(a in Attachment,
            where: a.user_id == ^user.id and a.vault_id == ^vault.id and a.path == "ghost.bin"
          )
          |> Engram.Repo.update_all(set: [content_nonce: :crypto.strong_rand_bytes(12)])
        end)

      assert {:error, :decrypt_failed} = Attachments.get_attachment(user, vault, "ghost.bin")
    end

    test "logs and returns {:error, {:storage, :blob_missing}} when storage object is gone" do
      user = insert(:user) |> Engram.Repo.reload!()
      vault = insert(:vault, user: user)
      path = "missing.bin"

      {:ok, _att} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => path,
          "content_base64" => Base.encode64("orphan me"),
          "mtime" => 0.0
        })

      # Delete the underlying object directly to simulate storage corruption
      # while leaving the DB row live.
      Engram.Storage.InMemory.delete("#{user.id}/#{vault.id}/#{path}")

      log =
        capture_log(fn ->
          assert {:error, {:storage, :blob_missing}} =
                   Attachments.get_attachment(user, vault, path)
        end)

      assert log =~ "Attachment blob missing"
    end
  end
end
