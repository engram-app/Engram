defmodule Engram.AttachmentsTest do
  use Engram.DataCase, async: false

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
    storage_key = "#{user.id}/#{vault.id}/#{@path}"
    %{user: user, vault: vault, storage_key: storage_key}
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

  describe "get_attachment/3 with S3 storage (content nil)" do
    test "fetches binary from storage backend when content is nil", %{user: user, vault: vault, storage_key: storage_key} do
      # Insert an attachment row with content: nil and a storage_key
      {:ok, _att} =
        Repo.with_tenant(user.id, fn ->
          %Attachment{}
          |> Attachment.changeset(%{
            path: @path,
            content: nil,
            content_hash: "abc123",
            mime_type: "image/png",
            size_bytes: 42,
            user_id: user.id,
            vault_id: vault.id,
            storage_key: storage_key
          })
          |> Repo.insert()
        end)

      expect(Engram.MockStorage, :get, fn _key ->
        {:ok, "binary content"}
      end)

      assert {:ok, %Attachment{content: "binary content"}} =
               Attachments.get_attachment(user, vault, @path)
    end

    test "returns storage error when blob is missing for live row", %{user: user, vault: vault, storage_key: storage_key} do
      {:ok, _att} =
        Repo.with_tenant(user.id, fn ->
          %Attachment{}
          |> Attachment.changeset(%{
            path: @path,
            content: nil,
            content_hash: "abc123",
            mime_type: "image/png",
            size_bytes: 42,
            user_id: user.id,
            vault_id: vault.id,
            storage_key: storage_key
          })
          |> Repo.insert()
        end)

      expect(Engram.MockStorage, :get, fn _key ->
        {:error, :not_found}
      end)

      log =
        capture_log(fn ->
          assert {:error, {:storage, :blob_missing}} = Attachments.get_attachment(user, vault, @path)
        end)

      assert log =~ "Attachment blob missing"
    end
  end
end
