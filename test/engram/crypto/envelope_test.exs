defmodule Engram.Crypto.EnvelopeTest do
  use ExUnit.Case, async: true
  alias Engram.Crypto.Envelope

  @dek :crypto.strong_rand_bytes(32)

  test "round-trips plaintext" do
    {ct, nonce} = Envelope.encrypt("hello world", @dek)
    assert {:ok, "hello world"} = Envelope.decrypt(ct, nonce, @dek)
  end

  test "produces unique nonces" do
    {_, n1} = Envelope.encrypt("x", @dek)
    {_, n2} = Envelope.encrypt("x", @dek)
    refute n1 == n2
    assert byte_size(n1) == 12
  end

  test "rejects tampered ciphertext" do
    {ct, nonce} = Envelope.encrypt("secret", @dek)
    <<first, rest::binary>> = ct
    tampered = <<Bitwise.bxor(first, 1), rest::binary>>
    assert :error = Envelope.decrypt(tampered, nonce, @dek)
  end

  test "rejects wrong key" do
    {ct, nonce} = Envelope.encrypt("secret", @dek)
    other_key = :crypto.strong_rand_bytes(32)
    assert :error = Envelope.decrypt(ct, nonce, other_key)
  end

  test "handles empty plaintext" do
    {ct, nonce} = Envelope.encrypt("", @dek)
    assert {:ok, ""} = Envelope.decrypt(ct, nonce, @dek)
  end

  test "rejects malformed (wrong-length) nonce" do
    {ct, _nonce} = Envelope.encrypt("secret", @dek)
    short_nonce = :crypto.strong_rand_bytes(8)
    assert :error = Envelope.decrypt(ct, short_nonce, @dek)

    long_nonce = :crypto.strong_rand_bytes(16)
    assert :error = Envelope.decrypt(ct, long_nonce, @dek)
  end

  # T3.6 / H1 — AAD binding. Each ciphertext is bound to a context string
  # ("<table>:<column>:<row_id>" for relational rows, "qdrant:<col>:<qid>:
  # <field>" for vector payload, "dek:v1:<user_id>" for wrapped DEK). A
  # tampered AAD or an attempted cross-row swap fails the AEAD tag check.

  describe "AAD binding (T3.6)" do
    test "round-trips with non-empty AAD" do
      aad = "notes:content:42"
      {ct, nonce} = Envelope.encrypt("body", @dek, aad)
      assert {:ok, "body"} = Envelope.decrypt(ct, nonce, @dek, aad)
    end

    test "wrong AAD fails decrypt" do
      {ct, nonce} = Envelope.encrypt("body", @dek, "notes:content:42")
      assert :error = Envelope.decrypt(ct, nonce, @dek, "notes:content:43")
    end

    test "missing AAD on read of AAD-bound ciphertext fails" do
      {ct, nonce} = Envelope.encrypt("body", @dek, "notes:content:42")
      # decrypt/3 (no AAD) treats AAD as <<>> for legacy compat — must
      # NOT accept AAD-bound ciphertext.
      assert :error = Envelope.decrypt(ct, nonce, @dek)
    end

    test "AAD-bound ciphertext from one row cannot be swapped into another" do
      {ct_a, nonce_a} = Envelope.encrypt("note A body", @dek, "notes:content:1")
      # Decrypting that ciphertext under row 2's AAD must fail — the
      # cross-row swap is exactly what AAD is supposed to defend against.
      assert :error = Envelope.decrypt(ct_a, nonce_a, @dek, "notes:content:2")
    end

    test "legacy 3-arity decrypt still works for ciphertext written without AAD" do
      {ct, nonce} = Envelope.encrypt("legacy", @dek)
      assert {:ok, "legacy"} = Envelope.decrypt(ct, nonce, @dek)
      # Equivalently, with explicit empty AAD.
      assert {:ok, "legacy"} = Envelope.decrypt(ct, nonce, @dek, <<>>)
    end
  end
end
