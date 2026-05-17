defmodule Engram.CryptoTest do
  use Engram.DataCase, async: false
  alias Engram.Crypto
  alias Engram.Crypto.DekCache

  setup do
    DekCache.invalidate_all()
    user = insert(:user)
    {:ok, user: user}
  end

  test "ensure_user_dek provisions a DEK once", %{user: user} do
    {:ok, user1} = Crypto.ensure_user_dek(user)
    assert is_binary(user1.encrypted_dek)
    assert user1.dek_version == 1
    assert user1.key_provider == "local"

    # Idempotent: calling again returns the same wrapped DEK
    {:ok, user2} = Crypto.ensure_user_dek(user1)
    assert user2.encrypted_dek == user1.encrypted_dek
  end

  test "ensure_user_dek does NOT rotate when caller holds a stale struct (encrypted_dek=nil) but DB has a blob",
       %{user: user} do
    # Regression for the data-corruption bug fixed in B.2.6: callers holding
    # a stale user struct (e.g. an in-memory copy fetched before encryption was
    # toggled on) would silently rotate the DEK on every ensure_user_dek call,
    # invalidating every existing ciphertext for the user.
    {:ok, provisioned} = Crypto.ensure_user_dek(user)
    assert is_binary(provisioned.encrypted_dek)
    original_blob = provisioned.encrypted_dek

    # `user` is the original fixture struct, still carrying encrypted_dek=nil.
    assert is_nil(user.encrypted_dek)

    {:ok, after_call} = Crypto.ensure_user_dek(user)

    assert after_call.encrypted_dek == original_blob,
           "stale-struct call rotated the DEK — every existing ciphertext is now unrecoverable"

    assert after_call.dek_version == provisioned.dek_version
    assert after_call.key_provider == provisioned.key_provider
  end

  test "get_dek caches after first unwrap", %{user: user} do
    {:ok, user} = Crypto.ensure_user_dek(user)
    # ensure_user_dek pre-populates the cache; clear it to exercise the unwrap path.
    DekCache.invalidate(user.id)
    assert :miss = DekCache.get(user.id)

    {:ok, dek} = Crypto.get_dek(user)
    assert byte_size(dek) == 32
    assert {:ok, ^dek} = DekCache.get(user.id)
  end

  test "get_dek returns error if no DEK provisioned", %{user: user} do
    assert {:error, :no_dek} = Crypto.get_dek(user)
  end

  describe "encrypt_note_fields/3" do
    test "encrypts content + title with row-id-bound AAD (T3.6)", %{user: user} do
      {:ok, user} = Crypto.ensure_user_dek(user)

      attrs = %{content: "secret", title: "Journal", tags: ["mood"]}
      {:ok, out} = Crypto.encrypt_note_fields(attrs, user, 4242)

      refute Map.has_key?(out, :content)
      refute Map.has_key?(out, :title)
      # Phase B.3+: tags are produced by phase_b_keyword_for only.
      refute Map.has_key?(out, :tags_ciphertext)
      assert is_binary(out.content_ciphertext)
      assert byte_size(out.content_nonce) == 12
      assert is_binary(out.title_ciphertext)
      assert byte_size(out.title_nonce) == 12
      # T3.6 — encrypt stamps the AAD-bound row version + propagates :id so
      # the caller can drop the changeset onto the pre-allocated row.
      assert out.id == 4242
      assert out.dek_version == Crypto.row_version_aad_bound()
    end
  end

  describe "maybe_decrypt_note_fields/2" do
    test "passes through note with no ciphertext", %{user: user} do
      {:ok, user} = Crypto.ensure_user_dek(user)
      note = %Engram.Notes.Note{content: nil, title: nil, tags: []}
      {:ok, out} = Crypto.maybe_decrypt_note_fields(note, user)
      assert out.content == nil
    end

    test "decrypts when ciphertext columns are present", %{user: user} do
      {:ok, user} = Crypto.ensure_user_dek(user)

      {:ok, encrypted} =
        Crypto.encrypt_note_fields(%{content: "secret", title: "T"}, user, 1234)

      {:ok, dek} = Crypto.get_dek(user)
      tags_bin = :erlang.term_to_binary(["x"])

      {tags_ct, tags_n} =
        Crypto.Envelope.encrypt(tags_bin, dek, Crypto.aad_for_row(:notes, :tags, 1234))

      note = %Engram.Notes.Note{
        id: 1234,
        dek_version: Crypto.row_version_aad_bound(),
        content_ciphertext: encrypted.content_ciphertext,
        content_nonce: encrypted.content_nonce,
        title_ciphertext: encrypted.title_ciphertext,
        title_nonce: encrypted.title_nonce,
        tags_ciphertext: tags_ct,
        tags_nonce: tags_n
      }

      {:ok, out} = Crypto.maybe_decrypt_note_fields(note, user)
      assert out.content == "secret"
      assert out.title == "T"
      assert out.tags == ["x"]
    end

    test "newly-inserted note rows carry dek_version=1 (T3.4 / H5)", %{user: user} do
      # T3.4 / H5 — the per-row column was added with default 1. New rows
      # inserted via the factory satisfy that default. This test locks the
      # contract so the column doesn't get accidentally dropped or
      # repurposed before the rotation flywheel uses it.
      vault = insert(:vault, user: user)
      note = insert(:note, user: user, vault: vault)

      reloaded =
        Engram.Repo.get!(Engram.Notes.Note, note.id, skip_tenant_check: true)

      assert reloaded.dek_version == 1
    end

    test "decrypts tags-only row (regression: T3.0.4 / M7 gate fix)", %{user: user} do
      # T3.0.4 — gate previously skipped decrypt when only tags_ciphertext
      # was set (content_ciphertext + path_ciphertext both nil). Latent
      # post-B.4, but a single ordering change in upsert could expose it.
      {:ok, user} = Crypto.ensure_user_dek(user)
      {:ok, dek} = Crypto.get_dek(user)
      tags_bin = :erlang.term_to_binary(["alpha", "beta"])
      {tags_ct, tags_n} = Crypto.Envelope.encrypt(tags_bin, dek)

      note = %Engram.Notes.Note{
        content_ciphertext: nil,
        path_ciphertext: nil,
        tags_ciphertext: tags_ct,
        tags_nonce: tags_n
      }

      {:ok, out} = Crypto.maybe_decrypt_note_fields(note, user)
      assert out.tags == ["alpha", "beta"]
    end
  end

  describe "dek_filter_key/1" do
    test "returns a deterministic 32-byte key for the same user" do
      user = insert(:user)
      {:ok, user} = Crypto.ensure_user_dek(user)

      {:ok, key1} = Crypto.dek_filter_key(user)
      {:ok, key2} = Crypto.dek_filter_key(user)

      assert is_binary(key1)
      assert byte_size(key1) == 32
      assert key1 == key2
    end

    test "returns different keys for different users" do
      user_a = insert(:user) |> Crypto.ensure_user_dek() |> elem(1)
      user_b = insert(:user) |> Crypto.ensure_user_dek() |> elem(1)

      {:ok, key_a} = Crypto.dek_filter_key(user_a)
      {:ok, key_b} = Crypto.dek_filter_key(user_b)

      refute key_a == key_b
    end

    test "is independent of the DEK itself (HKDF separation)" do
      user = insert(:user) |> Crypto.ensure_user_dek() |> elem(1)
      {:ok, dek} = Crypto.get_dek(user)
      {:ok, filter_key} = Crypto.dek_filter_key(user)

      refute filter_key == dek
    end
  end

  describe "dek_filter_key_from_bytes/1" do
    test "derives the same key as dek_filter_key/1 for the same DEK" do
      user = insert(:user) |> Crypto.ensure_user_dek() |> elem(1)
      {:ok, dek} = Crypto.get_dek(user)

      fk_via_cache = Crypto.dek_filter_key(user) |> elem(1)
      fk_from_bytes = Crypto.dek_filter_key_from_bytes(dek)

      assert byte_size(fk_from_bytes) == 32
      assert fk_from_bytes == fk_via_cache
    end

    test "returns a 32-byte binary from raw DEK bytes" do
      dek = :crypto.strong_rand_bytes(32)
      fk = Crypto.dek_filter_key_from_bytes(dek)

      assert is_binary(fk)
      assert byte_size(fk) == 32
    end

    test "different DEK bytes yield different filter keys" do
      dek_a = :crypto.strong_rand_bytes(32)
      dek_b = :crypto.strong_rand_bytes(32)

      refute Crypto.dek_filter_key_from_bytes(dek_a) == Crypto.dek_filter_key_from_bytes(dek_b)
    end

    test "dek_filter_key_from_bytes/1 equals dek_filter_key/1 for any user" do
      for _ <- 1..5 do
        user = insert(:user)
        {:ok, user} = Crypto.ensure_user_dek(user)
        {:ok, dek_bytes} = Crypto.get_dek(user)
        {:ok, key_via_user} = Crypto.dek_filter_key(user)
        key_via_bytes = Crypto.dek_filter_key_from_bytes(dek_bytes)
        assert key_via_user == key_via_bytes
      end
    end
  end

  describe "hmac_field/2" do
    test "returns deterministic 32-byte binary" do
      key = :crypto.strong_rand_bytes(32)

      h1 = Crypto.hmac_field(key, "projects/2026-q3")
      h2 = Crypto.hmac_field(key, "projects/2026-q3")

      assert is_binary(h1)
      assert byte_size(h1) == 32
      assert h1 == h2
    end

    test "different inputs yield different hashes for the same key" do
      key = :crypto.strong_rand_bytes(32)

      refute Crypto.hmac_field(key, "a") == Crypto.hmac_field(key, "b")
    end

    test "different keys yield different hashes for the same input" do
      k1 = :crypto.strong_rand_bytes(32)
      k2 = :crypto.strong_rand_bytes(32)

      refute Crypto.hmac_field(k1, "x") == Crypto.hmac_field(k2, "x")
    end
  end

  describe "dek_content_hash_key/1" do
    test "returns deterministic 32-byte key for the same user" do
      user = insert(:user) |> Crypto.ensure_user_dek() |> elem(1)

      {:ok, key1} = Crypto.dek_content_hash_key(user)
      {:ok, key2} = Crypto.dek_content_hash_key(user)

      assert is_binary(key1)
      assert byte_size(key1) == 32
      assert key1 == key2
    end

    test "returns different keys for different users" do
      a = insert(:user) |> Crypto.ensure_user_dek() |> elem(1)
      b = insert(:user) |> Crypto.ensure_user_dek() |> elem(1)

      {:ok, key_a} = Crypto.dek_content_hash_key(a)
      {:ok, key_b} = Crypto.dek_content_hash_key(b)

      refute key_a == key_b
    end

    test "domain-separated from filter_key (different HKDF info strings)" do
      user = insert(:user) |> Crypto.ensure_user_dek() |> elem(1)

      {:ok, content_key} = Crypto.dek_content_hash_key(user)
      {:ok, filter_key} = Crypto.dek_filter_key(user)

      refute content_key == filter_key
    end

    test "independent of the DEK itself" do
      user = insert(:user) |> Crypto.ensure_user_dek() |> elem(1)
      {:ok, dek} = Crypto.get_dek(user)
      {:ok, content_key} = Crypto.dek_content_hash_key(user)

      refute content_key == dek
    end

    test "returns {:error, :no_dek} when user has no DEK" do
      user = insert(:user)

      assert {:error, :no_dek} = Crypto.dek_content_hash_key(user)
    end
  end

  describe "hmac_content_hash/2" do
    test "returns 64-char lowercase hex string" do
      key = :crypto.strong_rand_bytes(32)

      hash = Crypto.hmac_content_hash(key, "any content here")

      assert is_binary(hash)
      assert String.length(hash) == 64
      assert hash =~ ~r/^[0-9a-f]{64}$/
    end

    test "deterministic for same key + content" do
      key = :crypto.strong_rand_bytes(32)

      assert Crypto.hmac_content_hash(key, "abc") ==
               Crypto.hmac_content_hash(key, "abc")
    end

    test "different content yields different hashes for same key" do
      key = :crypto.strong_rand_bytes(32)

      refute Crypto.hmac_content_hash(key, "a") ==
               Crypto.hmac_content_hash(key, "b")
    end

    test "different keys yield different hashes for same content" do
      k1 = :crypto.strong_rand_bytes(32)
      k2 = :crypto.strong_rand_bytes(32)

      refute Crypto.hmac_content_hash(k1, "x") ==
               Crypto.hmac_content_hash(k2, "x")
    end

    test "result is NOT equal to legacy MD5 hex of same content" do
      key = :crypto.strong_rand_bytes(32)
      content = "hello"
      legacy_md5 = :crypto.hash(:md5, content) |> Base.encode16(case: :lower)

      refute Crypto.hmac_content_hash(key, content) == legacy_md5
    end

    test "handles empty content" do
      key = :crypto.strong_rand_bytes(32)
      hash = Crypto.hmac_content_hash(key, "")
      assert String.length(hash) == 64
      assert hash =~ ~r/^[0-9a-f]{64}$/
    end
  end

  describe "get_dek/1 dual-read + lazy migration" do
    use Oban.Testing, repo: Engram.Repo
    import Mox
    setup :verify_on_exit!

    setup do
      original_master_key = Application.get_env(:engram, :encryption_master_key)
      original_kms_client = Application.get_env(:engram, :aws_kms_client)
      original_provider = Application.get_env(:engram, :key_provider)

      on_exit(fn ->
        if original_master_key,
          do: Application.put_env(:engram, :encryption_master_key, original_master_key),
          else: Application.delete_env(:engram, :encryption_master_key)

        if original_kms_client,
          do: Application.put_env(:engram, :aws_kms_client, original_kms_client),
          else: Application.delete_env(:engram, :aws_kms_client)

        if original_provider,
          do: Application.put_env(:engram, :key_provider, original_provider),
          else: Application.delete_env(:engram, :key_provider)
      end)

      Application.put_env(
        :engram,
        :encryption_master_key,
        Base.encode64(:crypto.strong_rand_bytes(32))
      )

      Application.put_env(:engram, :aws_kms_client, Engram.AwsKmsMock)

      table = :ets.new(:dual_read_stub, [:set, :public])

      stub(Engram.AwsKmsMock, :encrypt, fn pt, _ ->
        ct = :crypto.strong_rand_bytes(48)
        :ets.insert(table, {ct, pt})
        {:ok, ct}
      end)

      stub(Engram.AwsKmsMock, :decrypt, fn ct, _ ->
        case :ets.lookup(table, ct) do
          [{^ct, pt}] -> {:ok, pt}
          [] -> {:error, :context_mismatch}
        end
      end)

      stub(Engram.AwsKmsMock, :describe_key, fn -> :ok end)
      :ok
    end

    defp make_user_with_provider!(provider_module) do
      Application.put_env(:engram, :key_provider, provider_module)
      user = insert(:user)
      {:ok, user} = Crypto.ensure_user_dek(user)
      DekCache.delete(user.id)
      user
    end

    test "Local blob + KEY_PROVIDER=local → succeeds, no enqueue" do
      user = make_user_with_provider!(Engram.Crypto.KeyProvider.Local)
      Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.Local)

      assert {:ok, <<_::256>>} = Crypto.get_dek(user)

      refute_enqueued(worker: Engram.Workers.MigrateUserProvider, args: %{"user_id" => user.id})
    end

    test "Local blob + KEY_PROVIDER=aws_kms → succeeds via Local, enqueues lazy migration to KMS" do
      user = make_user_with_provider!(Engram.Crypto.KeyProvider.Local)
      Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.AwsKms)

      assert {:ok, <<_::256>>} = Crypto.get_dek(user)

      assert_enqueued(
        worker: Engram.Workers.MigrateUserProvider,
        args: %{"user_id" => user.id, "target_provider" => "aws_kms"}
      )
    end

    test "KMS blob + KEY_PROVIDER=aws_kms → succeeds, no enqueue" do
      user = make_user_with_provider!(Engram.Crypto.KeyProvider.AwsKms)
      Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.AwsKms)

      assert {:ok, <<_::256>>} = Crypto.get_dek(user)

      refute_enqueued(worker: Engram.Workers.MigrateUserProvider, args: %{"user_id" => user.id})
    end

    test "KMS blob + KEY_PROVIDER=local → succeeds via KMS, enqueues reverse migration to local" do
      user = make_user_with_provider!(Engram.Crypto.KeyProvider.AwsKms)
      Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.Local)

      assert {:ok, <<_::256>>} = Crypto.get_dek(user)

      assert_enqueued(
        worker: Engram.Workers.MigrateUserProvider,
        args: %{"user_id" => user.id, "target_provider" => "local"}
      )
    end

    test "cache hit short-circuits identify_from_blob — no lazy enqueue on cache hit" do
      user = make_user_with_provider!(Engram.Crypto.KeyProvider.Local)
      Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.AwsKms)

      # First call: miss → unwrap → enqueue.
      {:ok, dek} = Crypto.get_dek(user)
      assert_enqueued(worker: Engram.Workers.MigrateUserProvider, args: %{"user_id" => user.id})

      # Snapshot enqueue count, then make a second call — cache hit returns
      # immediately without calling identify_from_blob, so no second enqueue.
      first_count =
        all_enqueued(worker: Engram.Workers.MigrateUserProvider)
        |> Enum.count(&(&1.args["user_id"] == user.id))

      assert {:ok, ^dek} = Crypto.get_dek(user)

      second_count =
        all_enqueued(worker: Engram.Workers.MigrateUserProvider)
        |> Enum.count(&(&1.args["user_id"] == user.id))

      assert first_count == second_count
    end
  end
end
