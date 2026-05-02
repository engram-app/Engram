defmodule Engram.Workers.EncryptAttachmentsTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Attachments
  alias Engram.Attachments.Attachment
  alias Engram.Repo
  alias Engram.Workers.EncryptAttachments

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)

    user = insert(:user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  describe "perform/1" do
    test "encrypts a single legacy BYTEA attachment in place", %{user: user, vault: vault} do
      legacy_bytes = "totally-plaintext-payload"

      {:ok, {:ok, att}} =
        Repo.with_tenant(user.id, fn ->
          %Attachment{}
          |> Attachment.changeset(%{
            path: "legacy/old.bin",
            content: legacy_bytes,
            content_hash: :crypto.hash(:md5, legacy_bytes) |> Base.encode16(case: :lower),
            mime_type: "application/octet-stream",
            size_bytes: byte_size(legacy_bytes),
            user_id: user.id,
            vault_id: vault.id,
            storage_key: "#{user.id}/#{vault.id}/legacy/old.bin",
            encryption_version: 0
          })
          |> Repo.insert()
        end)

      assert :ok =
               perform_job(EncryptAttachments, %{
                 "vault_id" => vault.id,
                 "user_id" => user.id,
                 "cursor" => 0
               })

      reloaded = Repo.get!(Attachment, att.id, skip_tenant_check: true)
      assert reloaded.encryption_version == 1
      assert is_binary(reloaded.content_nonce)
      assert byte_size(reloaded.content_nonce) == 12
      assert reloaded.content != legacy_bytes
      assert byte_size(reloaded.content) == byte_size(legacy_bytes) + 16

      user = Repo.reload!(user)
      assert {:ok, %Attachment{content: ^legacy_bytes}} =
               Attachments.get_attachment(user, vault, "legacy/old.bin")
    end

    test "skips already-encrypted rows (version=1)", %{user: user, vault: vault} do
      pid = self()

      expect(Engram.MockStorage, :put, fn _key, ct, _opts ->
        send(pid, {:initial_put, ct})
        :ok
      end)

      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "fresh.bin",
          "content_base64" => Base.encode64("fresh-content")
        })

      assert_receive {:initial_put, _original_ct}

      # Worker run should be a no-op for v=1 rows.
      assert :ok =
               perform_job(EncryptAttachments, %{
                 "vault_id" => vault.id,
                 "user_id" => user.id,
                 "cursor" => 0
               })

      [att] =
        Repo.with_tenant(user.id, fn ->
          import Ecto.Query
          Repo.all(from a in Attachment, where: a.vault_id == ^vault.id)
        end)
        |> elem(1)

      # Nonce + ciphertext unchanged — worker did not double-encrypt.
      assert att.encryption_version == 1
      refute is_nil(att.content_nonce)
    end

    test "encrypts S3-backed legacy attachment via storage adapter round-trip", %{
      user: user,
      vault: vault
    } do
      pid = self()
      legacy_bytes = "s3-stored-legacy"
      key = "#{user.id}/#{vault.id}/s3-legacy.bin"

      {:ok, _att} =
        Repo.with_tenant(user.id, fn ->
          %Attachment{}
          |> Attachment.changeset(%{
            path: "s3-legacy.bin",
            content: nil,
            content_hash: :crypto.hash(:md5, legacy_bytes) |> Base.encode16(case: :lower),
            mime_type: "application/octet-stream",
            size_bytes: byte_size(legacy_bytes),
            user_id: user.id,
            vault_id: vault.id,
            storage_key: key,
            encryption_version: 0
          })
          |> Repo.insert()
        end)

      expect(Engram.MockStorage, :get, fn ^key -> {:ok, legacy_bytes} end)

      expect(Engram.MockStorage, :put, fn ^key, ct, _opts ->
        send(pid, {:rewrite, ct})
        :ok
      end)

      assert :ok =
               perform_job(EncryptAttachments, %{
                 "vault_id" => vault.id,
                 "user_id" => user.id,
                 "cursor" => 0
               })

      assert_receive {:rewrite, ciphertext}
      refute ciphertext == legacy_bytes
      assert byte_size(ciphertext) == byte_size(legacy_bytes) + 16

      [reloaded] =
        Repo.with_tenant(user.id, fn ->
          import Ecto.Query
          Repo.all(from a in Attachment, where: a.vault_id == ^vault.id)
        end)
        |> elem(1)

      assert reloaded.encryption_version == 1
      assert is_binary(reloaded.content_nonce)
      # S3 adapter never persists content in BYTEA
      assert is_nil(reloaded.content)
    end
  end

  describe "enqueue_legacy_vaults/0" do
    test "enqueues one job per vault holding legacy attachments", %{user: user, vault: vault_a} do
      vault_b = insert(:vault, user: user)

      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          %Attachment{}
          |> Attachment.changeset(%{
            path: "legacy.bin",
            content: "abc",
            content_hash: "deadbeef",
            mime_type: "application/octet-stream",
            size_bytes: 3,
            user_id: user.id,
            vault_id: vault_a.id,
            storage_key: "#{user.id}/#{vault_a.id}/legacy.bin",
            encryption_version: 0
          })
          |> Repo.insert()
        end)

      {:ok, count} = EncryptAttachments.enqueue_legacy_vaults()
      assert count == 1

      assert_enqueued worker: EncryptAttachments,
                      args: %{"vault_id" => vault_a.id, "user_id" => user.id, "cursor" => 0}

      refute_enqueued worker: EncryptAttachments, args: %{"vault_id" => vault_b.id}
    end

    test "ignores already-encrypted attachments", %{user: user, vault: vault} do
      pid = self()

      expect(Engram.MockStorage, :put, fn _key, ct, _opts ->
        send(pid, {:put, ct})
        :ok
      end)

      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "fresh.bin",
          "content_base64" => Base.encode64("hello")
        })

      {:ok, count} = EncryptAttachments.enqueue_legacy_vaults()
      assert count == 0
      refute_enqueued worker: EncryptAttachments
    end
  end
end
