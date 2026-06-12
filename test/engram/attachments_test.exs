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

  describe "concurrent upsert race (T3-audit H1)" do
    # T3-audit H1 — pre-fix, two concurrent upserts to the same path could
    # race: each reads "no existing row," allocates a fresh att_id, encrypts
    # blob with AAD bound to its own id, and PUTs to the same S3 key (last
    # writer wins). The DB row that survives the unique-path_hmac constraint
    # may have an id that doesn't match the AAD baked into the blob → next
    # GET decrypt fails with `:decrypt_failed`. Fix: serialize same-path
    # upserts via `pg_advisory_xact_lock` keyed on (user_id, path_hmac).
    test "upsert_attachment/3 wraps allocation + write in Repo.transaction with advisory lock" do
      src = File.read!("lib/engram/attachments.ex")

      assert src =~ ~r/pg_advisory_xact_lock/,
             "upsert_attachment must take a per-(user, path_hmac) advisory lock " <>
               "to serialize concurrent same-path uploads (T3-audit H1)"

      assert src =~ ~r/Repo\.transaction/,
             "upsert_attachment must wrap the allocation + insert in a transaction so " <>
               "the advisory lock auto-releases on commit/rollback (T3-audit H1)"
    end
  end

  describe "upsert_attachment/3 transaction shape" do
    test "S3 PUT runs outside the row transaction on the common path", %{
      user: user,
      vault: vault
    } do
      # A slow S3 PUT inside the transaction holds a pool connection (and
      # the per-path advisory lock) for the whole upload — ~10 concurrent
      # uploads can starve the entire API of DB connections.
      test_pid = self()

      expect(Engram.MockStorage, :put, fn _key, _binary, _opts ->
        send(test_pid, {:put_in_txn, Engram.Repo.in_transaction?()})
        :ok
      end)

      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => @path,
          "content_base64" => @valid_content
        })

      assert_received {:put_in_txn, false}
    end

    test "raced first-upload converges: blob AAD re-bound to the surviving row id", %{
      user: user,
      vault: vault
    } do
      # With the PUT outside the lock, two concurrent first-uploads can
      # encrypt under different att_ids. The locked re-read must detect
      # that the surviving row id differs from the AAD baked into the
      # uploaded blob and re-encrypt + re-PUT under the lock (T3-audit H1
      # invariant: surviving blob AAD == surviving row id).
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
      path_hmac = Engram.Crypto.hmac_field(filter_key, @path)
      competing_id = Ecto.UUID.generate()

      {:ok, raced} = Agent.start_link(fn -> false end)

      stub(Engram.MockStorage, :get, &Engram.Storage.InMemory.get/1)

      expect(Engram.MockStorage, :put, 2, fn key, binary, opts ->
        # First PUT happens in the pre-lock window — simulate a concurrent
        # upsert winning the lock first by inserting the surviving row now.
        unless Agent.get_and_update(raced, &{&1, true}) do
          insert(:attachment,
            id: competing_id,
            user: user,
            vault: vault,
            path_hmac: path_hmac
          )
        end

        Engram.Storage.InMemory.put(key, binary, opts)
      end)

      {:ok, att} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => @path,
          "content_base64" => @valid_content
        })

      # The pre-existing row won; our upload updated it rather than
      # inserting a duplicate path.
      assert att.id == competing_id

      # End-to-end proof the blob decrypts under the surviving id.
      {:ok, fetched} = Attachments.get_attachment(user, vault, @path)
      assert fetched.content == Base.decode64!(@valid_content)
    end
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

    test "rejects attachment over per-plan max_file_bytes (§G)",
         %{user: user, vault: vault} do
      Engram.Factory.insert(:user_limit_override,
        user: user,
        key: "max_file_bytes",
        value: %{"v" => 1_048_576}
      )

      oversized = Base.encode64(:binary.copy("x", 1_048_576 + 1))

      assert {:error, {:too_large, 1_048_576}} =
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

    test "Phase B dual-write — populates path_hmac/ciphertext/nonce", %{user: user, vault: vault} do
      expect(Engram.MockStorage, :put, fn _key, _binary, _opts -> :ok end)

      # Ensure user has DEK before calling upsert_attachment
      user = user |> Engram.Repo.reload!()
      {:ok, _} = Engram.Crypto.ensure_user_dek(user)
      user = user |> Engram.Repo.reload!()

      {:ok, att} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "photos/test.png",
          "content_base64" => Base.encode64("img bytes")
        })

      {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
      expected_hmac = Engram.Crypto.hmac_field(filter_key, "photos/test.png")

      assert att.path_hmac == expected_hmac
      assert is_binary(att.path_ciphertext)
      assert byte_size(att.path_nonce) == 12
      assert att.path == "photos/test.png", "dual-write keeps plaintext path until B.3"
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

    test "get_attachment locates row via path_hmac" do
      user = insert(:user) |> Engram.Repo.reload!()
      vault = insert(:vault, user: user)

      {:ok, created} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "Real/file.bin",
          "content_base64" => Base.encode64("hello"),
          "mtime" => 0.0
        })

      assert {:ok, fetched} = Attachments.get_attachment(user, vault, "Real/file.bin")
      assert fetched.id == created.id
      assert fetched.path == "Real/file.bin"
    end

    test "list_changes returns decrypt-sourced path" do
      user = insert(:user) |> Engram.Repo.reload!()
      vault = insert(:vault, user: user)

      {:ok, _created} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "Notes/img.png",
          "content_base64" => Base.encode64("img"),
          "mtime" => 0.0
        })

      assert {:ok, [change]} =
               Attachments.list_changes(user, vault, ~U[2000-01-01 00:00:00.000000Z])

      assert change.path == "Notes/img.png"
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

      ghost = Engram.Fixtures.raw_attachment_by_path!(user, "ghost.bin")

      {:ok, _} =
        Engram.Repo.with_tenant(user.id, fn ->
          from(a in Attachment, where: a.id == ^ghost.id)
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
