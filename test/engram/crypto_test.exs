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

  describe "maybe_encrypt_note_fields/3" do
    test "passes through when vault is not encrypted", %{user: user} do
      {:ok, user} = Crypto.ensure_user_dek(user)
      vault = %Engram.Vaults.Vault{encrypted: false}

      attrs = %{content: "hi", title: "t", tags: ["a", "b"]}
      {:ok, out} = Crypto.maybe_encrypt_note_fields(attrs, user, vault)

      assert out.content == "hi"
      refute Map.has_key?(out, :content_ciphertext)
    end

    test "encrypts when vault is encrypted", %{user: user} do
      {:ok, user} = Crypto.ensure_user_dek(user)
      vault = %Engram.Vaults.Vault{encrypted: true}

      attrs = %{content: "secret", title: "Journal", tags: ["mood"]}
      {:ok, out} = Crypto.maybe_encrypt_note_fields(attrs, user, vault)

      assert out.content == nil
      assert out.title == nil
      assert out.tags == nil
      assert is_binary(out.content_ciphertext)
      assert byte_size(out.content_nonce) == 12
      assert is_binary(out.tags_ciphertext)
    end
  end

  describe "maybe_decrypt_note_fields/2" do
    test "passes through unencrypted note", %{user: user} do
      {:ok, user} = Crypto.ensure_user_dek(user)
      note = %Engram.Notes.Note{content: "plain", title: "t", tags: ["a"]}
      {:ok, out} = Crypto.maybe_decrypt_note_fields(note, user)
      assert out.content == "plain"
    end

    test "decrypts when ciphertext columns are present", %{user: user} do
      {:ok, user} = Crypto.ensure_user_dek(user)
      vault = %Engram.Vaults.Vault{encrypted: true}

      {:ok, encrypted} =
        Crypto.maybe_encrypt_note_fields(
          %{content: "secret", title: "T", tags: ["x"]},
          user,
          vault
        )

      note = %Engram.Notes.Note{
        content: nil,
        title: nil,
        tags: nil,
        content_ciphertext: encrypted.content_ciphertext,
        content_nonce: encrypted.content_nonce,
        title_ciphertext: encrypted.title_ciphertext,
        title_nonce: encrypted.title_nonce,
        tags_ciphertext: encrypted.tags_ciphertext,
        tags_nonce: encrypted.tags_nonce
      }

      {:ok, out} = Crypto.maybe_decrypt_note_fields(note, user)
      assert out.content == "secret"
      assert out.title == "T"
      assert out.tags == ["x"]
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
end
