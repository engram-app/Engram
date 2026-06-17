defmodule Engram.AttachmentsTest do
  use Engram.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Mox

  alias Engram.Attachments
  alias Engram.Attachments.Attachment
  alias Engram.Crypto
  alias Engram.Storage.InMemory

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

  describe "storage failure surfacing" do
    test "logs the underlying storage reason when the S3 PUT fails", %{
      user: user,
      vault: vault
    } do
      # A storage PUT failure (e.g. SignatureDoesNotMatch on a misconfigured
      # MinIO secret) becomes a 502 to the client. Without a log line the
      # operator has no way to tell why — the reason must hit the server log.
      expect(Engram.MockStorage, :put, fn _key, _binary, _opts ->
        {:error, {:http_error, 403, "SignatureDoesNotMatch"}}
      end)

      log =
        capture_log(fn ->
          assert {:error, {:storage, _reason}} =
                   Attachments.upsert_attachment(user, vault, %{
                     "path" => @path,
                     "content_base64" => @valid_content
                   })
        end)

      assert log =~ "attachment storage"
      assert log =~ "SignatureDoesNotMatch"
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
      {:ok, user} = Crypto.ensure_user_dek(user)
      {:ok, filter_key} = Crypto.dek_filter_key(user)
      path_hmac = Crypto.hmac_field(filter_key, @path)
      competing_id = Ecto.UUID.generate()

      {:ok, raced} = Agent.start_link(fn -> false end)

      stub(Engram.MockStorage, :get, &InMemory.get/1)

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

        InMemory.put(key, binary, opts)
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
      {:ok, _} = Crypto.ensure_user_dek(user)
      user = user |> Engram.Repo.reload!()

      {:ok, att} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "photos/test.png",
          "content_base64" => Base.encode64("img bytes")
        })

      {:ok, filter_key} = Crypto.dek_filter_key(user)
      expected_hmac = Crypto.hmac_field(filter_key, "photos/test.png")

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

  describe "list_attachments/2" do
    setup do
      Mox.stub_with(Engram.MockStorage, Engram.Storage.InMemory)
      :ok
    end

    test "returns non-deleted attachment metadata for the vault", %{user: user, vault: vault} do
      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "img/a.png",
          "content_base64" => Base.encode64("PNGDATA"),
          "mime_type" => "image/png"
        })

      {:ok, _b} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "b.pdf",
          "content_base64" => Base.encode64("PDFDATA"),
          "mime_type" => "application/pdf"
        })

      :ok = Attachments.delete_attachment(user, vault, "b.pdf")

      {:ok, list} = Attachments.list_attachments(user, vault)

      paths = Enum.map(list, & &1.path)
      assert "img/a.png" in paths
      refute "b.pdf" in paths

      a = Enum.find(list, &(&1.path == "img/a.png"))
      assert a.mime_type == "image/png"
      assert a.size_bytes == byte_size("PNGDATA")
      assert Map.has_key?(a, :updated_at)
      assert a.id != nil
      refute Map.has_key?(a, :deleted_at)
    end

    test "scopes to the given user+vault", %{user: user, vault: vault} do
      other = insert(:user)
      other_vault = insert(:vault, user: other)

      {:ok, _} =
        Attachments.upsert_attachment(other, other_vault, %{
          "path" => "secret.png",
          "content_base64" => Base.encode64("X"),
          "mime_type" => "image/png"
        })

      {:ok, list} = Attachments.list_attachments(user, vault)
      refute Enum.any?(list, &(&1.path == "secret.png"))
    end

    test "skips an undecryptable row instead of crashing the whole list",
         %{user: user, vault: vault} do
      {:ok, _good} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "good.png",
          "content_base64" => Base.encode64("X"),
          "mime_type" => "image/png"
        })

      {:ok, bad} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "bad.png",
          "content_base64" => Base.encode64("Y"),
          "mime_type" => "image/png"
        })

      # Corrupt the bad row's path ciphertext → decrypt_metadata returns
      # {:error, :decrypt_failed} for it (AEAD verification fails).
      Engram.Repo.with_tenant(user.id, fn ->
        from(a in Attachment, where: a.id == ^bad.id)
        |> Engram.Repo.update_all(set: [path_ciphertext: :crypto.strong_rand_bytes(48)])
      end)

      log =
        capture_log(fn ->
          {:ok, list} = Attachments.list_attachments(user, vault)
          paths = Enum.map(list, & &1.path)
          assert "good.png" in paths
          refute "bad.png" in paths
          assert length(list) == 1
        end)

      assert log =~ "Skipping undecryptable attachment"
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

      {:ok, att} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => path,
          "content_base64" => Base.encode64("orphan me"),
          "mtime" => 0.0
        })

      # Delete the underlying object directly to simulate storage corruption
      # while leaving the DB row live. Blobs are UUID-keyed since Task 2.
      InMemory.delete(att.storage_key)

      log =
        capture_log(fn ->
          assert {:error, {:storage, :blob_missing}} =
                   Attachments.get_attachment(user, vault, path)
        end)

      assert log =~ "Attachment blob missing"
    end
  end

  describe "uuid-keyed storage (Task 2)" do
    setup do
      Mox.stub_with(Engram.MockStorage, Engram.Storage.InMemory)
      :ok
    end

    test "new upload keys storage by uuid, not by path", %{user: user, vault: vault} do
      {:ok, att} = Attachments.upsert_attachment(user, vault, %{
        "path" => "img/cat.png", "content_base64" => Base.encode64("PNGDATA"),
        "mime_type" => "image/png", "mtime" => 1.0
      })
      assert att.storage_key =~ ~r{/objects/#{att.id}$}
      refute att.storage_key =~ "img/cat.png"
    end

    test "a new upload to a vacated path does NOT clobber a different blob", %{user: user, vault: vault} do
      {:ok, a} = Attachments.upsert_attachment(user, vault, %{
        "path" => "p/x.png", "content_base64" => Base.encode64("AAA"),
        "mime_type" => "image/png", "mtime" => 1.0
      })
      :ok = Attachments.delete_attachment(user, vault, "p/x.png")
      {:ok, b} = Attachments.upsert_attachment(user, vault, %{
        "path" => "p/x.png", "content_base64" => Base.encode64("BBB"),
        "mime_type" => "image/png", "mtime" => 2.0
      })
      refute a.storage_key == b.storage_key
    end
  end

  describe "move_attachment/4" do
    setup %{user: user, vault: vault} do
      Mox.stub_with(Engram.MockStorage, Engram.Storage.InMemory)

      {:ok, att} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "old/a.png",
          "content_base64" => Base.encode64("DATA"),
          "mime_type" => "image/png",
          "mtime" => 1.0
        })

      %{att: att}
    end

    test "repoints the live row, blob/storage_key untouched", %{
      user: user,
      vault: vault,
      att: att
    } do
      {:ok, moved} = Attachments.move_attachment(user, vault, "old/a.png", "new/b.png")
      assert moved.id == att.id
      assert moved.path == "new/b.png"
      assert moved.storage_key == att.storage_key
      {:ok, fetched} = Attachments.get_attachment(user, vault, "new/b.png")
      assert fetched.content == "DATA"
    end

    test "emits a soft-deleted tombstone at the old path", %{user: user, vault: vault} do
      {:ok, _} = Attachments.move_attachment(user, vault, "old/a.png", "new/b.png")
      {:ok, %{changes: changes}} = Attachments.list_changes_by_seq(user, vault, 0)
      assert Enum.any?(changes, &(&1.path == "old/a.png" and &1.deleted))
      assert Enum.any?(changes, &(&1.path == "new/b.png" and not &1.deleted))
    end

    test "conflict on occupied target → :conflict", %{user: user, vault: vault} do
      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "new/b.png",
          "content_base64" => Base.encode64("X"),
          "mime_type" => "image/png",
          "mtime" => 1.0
        })

      assert {:error, :conflict} = Attachments.move_attachment(user, vault, "old/a.png", "new/b.png")
    end

    test "no-op move (old == new) is idempotent, no tombstone", %{user: user, vault: vault} do
      {:ok, _} = Attachments.move_attachment(user, vault, "old/a.png", "old/a.png")
      {:ok, %{changes: changes}} = Attachments.list_changes_by_seq(user, vault, 0)
      refute Enum.any?(changes, & &1.deleted)
    end

    test "missing source → :not_found", %{user: user, vault: vault} do
      assert {:error, :not_found} = Attachments.move_attachment(user, vault, "nope.png", "x.png")
    end
  end

  describe "batch_move/4 + batch_delete/3" do
    setup %{user: user, vault: vault} do
      Mox.stub_with(Engram.MockStorage, Engram.Storage.InMemory)

      for p <- ["a.png", "b.png"] do
        {:ok, _} = Attachments.upsert_attachment(user, vault, %{
          "path" => p, "content_base64" => Base.encode64(p),
          "mime_type" => "image/png", "mtime" => 1.0
        })
      end

      :ok
    end

    test "batch_move relocates each into the target folder", %{user: user, vault: vault} do
      {:ok, %{moved: 2}} = Attachments.batch_move(user, vault, ["a.png", "b.png"], "img")
      {:ok, _} = Attachments.get_attachment(user, vault, "img/a.png")
      {:ok, _} = Attachments.get_attachment(user, vault, "img/b.png")
    end

    test "batch_move to root keeps basenames", %{user: user, vault: vault} do
      {:ok, _} = Attachments.batch_move(user, vault, ["a.png"], "img")
      {:ok, %{moved: 1}} = Attachments.batch_move(user, vault, ["img/a.png"], "")
      {:ok, _} = Attachments.get_attachment(user, vault, "a.png")
    end

    test "batch_move rolls back on conflict", %{user: user, vault: vault} do
      {:ok, _} = Attachments.upsert_attachment(user, vault, %{
        "path" => "img/a.png", "content_base64" => Base.encode64("X"),
        "mime_type" => "image/png", "mtime" => 1.0
      })
      assert {:error, {:conflict, "a.png"}} = Attachments.batch_move(user, vault, ["a.png"], "img")
      # a.png still at root (rolled back)
      {:ok, _} = Attachments.get_attachment(user, vault, "a.png")
    end

    test "batch_move reverts an already-moved item when a later item conflicts",
         %{user: user, vault: vault} do
      # Pre-occupy the target of the SECOND item so a.png moves first, then
      # b.png conflicts — proving the whole batch (incl. a.png) rolls back.
      {:ok, _} = Attachments.upsert_attachment(user, vault, %{
        "path" => "img/b.png", "content_base64" => Base.encode64("X"),
        "mime_type" => "image/png", "mtime" => 1.0
      })

      assert {:error, {:conflict, "b.png"}} =
               Attachments.batch_move(user, vault, ["a.png", "b.png"], "img")

      # a.png's earlier move was rolled back: still at root, NOT at img/a.png.
      {:ok, _} = Attachments.get_attachment(user, vault, "a.png")
      {:ok, nil} = Attachments.get_attachment(user, vault, "img/a.png")
    end

    test "batch_delete soft-deletes each", %{user: user, vault: vault} do
      {:ok, %{deleted: 2}} = Attachments.batch_delete(user, vault, ["a.png", "b.png"])
      {:ok, nil} = Attachments.get_attachment(user, vault, "a.png")
      {:ok, nil} = Attachments.get_attachment(user, vault, "b.png")
    end

    test "batch_delete counts only paths that held a live row", %{user: user, vault: vault} do
      {:ok, %{deleted: 1}} = Attachments.batch_delete(user, vault, ["a.png", "absent.png"])
    end
  end

  describe "note_changed broadcast (kind=attachment)" do
    setup do
      Mox.stub_with(Engram.MockStorage, Engram.Storage.InMemory)
      :ok
    end

    test "move broadcasts delete(old) + upsert(new) with kind=attachment", %{user: user, vault: vault} do
      {:ok, att} = Attachments.upsert_attachment(user, vault, %{
        "path" => "old/a.png", "content_base64" => Base.encode64("D"),
        "mime_type" => "image/png", "mtime" => 1.0
      })
      topic = "sync:#{user.id}:#{vault.id}"
      EngramWeb.Endpoint.subscribe(topic)

      {:ok, _} = Attachments.move_attachment(user, vault, "old/a.png", "new/b.png")

      assert_receive %Phoenix.Socket.Broadcast{
        event: "note_changed",
        payload: %{"event_type" => "delete", "kind" => "attachment", "path" => "old/a.png"}
      }
      assert_receive %Phoenix.Socket.Broadcast{
        event: "note_changed",
        payload: %{"event_type" => "upsert", "kind" => "attachment", "path" => "new/b.png",
                   "mime_type" => "image/png"}
      }
      _ = att
    end

    test "delete_attachment broadcasts delete with kind=attachment", %{user: user, vault: vault} do
      {:ok, _} = Attachments.upsert_attachment(user, vault, %{
        "path" => "gone.png", "content_base64" => Base.encode64("D"),
        "mime_type" => "image/png", "mtime" => 1.0
      })
      topic = "sync:#{user.id}:#{vault.id}"
      EngramWeb.Endpoint.subscribe(topic)

      :ok = Attachments.delete_attachment(user, vault, "gone.png")

      assert_receive %Phoenix.Socket.Broadcast{
        event: "note_changed",
        payload: %{"event_type" => "delete", "kind" => "attachment", "path" => "gone.png"}
      }
    end

    test "deleting an absent path broadcasts nothing", %{user: user, vault: vault} do
      topic = "sync:#{user.id}:#{vault.id}"
      EngramWeb.Endpoint.subscribe(topic)

      :ok = Attachments.delete_attachment(user, vault, "never-existed.png")

      refute_receive %Phoenix.Socket.Broadcast{event: "note_changed"}
    end
  end
end
