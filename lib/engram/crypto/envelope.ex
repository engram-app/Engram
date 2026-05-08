defmodule Engram.Crypto.Envelope do
  @moduledoc """
  Stateless AES-256-GCM authenticated encryption with associated data (AAD).

  Ciphertext layout returned by `encrypt/3` is `ciphertext || tag` (16-byte
  tag suffix). The nonce is returned separately; callers store it alongside
  ciphertext.

  ## AAD (T3.6 / H1)

  Every ciphertext is bound to a context string via AES-GCM's AAD slot.
  Tampering with AAD on read fails the AEAD tag check, even though AAD
  itself is not encrypted. Per-row AAD makes within-user cross-row swaps
  detectable: copying `notes.content_ciphertext + content_nonce` from row
  42 into row 99 cannot decrypt under row 99's reconstructed AAD.

  AAD shape per call site:

    * Relational rows  — `"<table>:<column>:<row_id>"` (e.g. `"notes:content:42"`)
    * Qdrant payload   — `"qdrant:<collection>:<qdrant_id>:<field>"`
    * Wrapped DEK      — `"dek:v1:<user_id>"`

  ## Backwards compatibility

  Pre-T3.6 ciphertext was written with empty AAD (`<<>>`). The 2/3-arity
  `encrypt/2` / `decrypt/3` clauses delegate to the AAD-aware arity with
  `<<>>` so legacy reads keep working. Per-row `dek_version` (notes /
  attachments / vaults) and the wrap-format byte (users.encrypted_dek)
  signal whether a constructed AAD or `<<>>` should be supplied — that
  decision lives at the caller, not here.
  """

  @cipher :aes_256_gcm
  @nonce_bytes 12
  @tag_bytes 16

  @typedoc "AES-GCM Additional Authenticated Data — bound to ciphertext but not encrypted."
  @type aad :: binary()

  @spec encrypt(binary(), <<_::256>>) :: {binary(), binary()}
  def encrypt(plaintext, dek), do: encrypt(plaintext, dek, <<>>)

  @spec encrypt(binary(), <<_::256>>, aad()) :: {binary(), binary()}
  def encrypt(plaintext, <<_::256>> = dek, aad)
      when is_binary(plaintext) and is_binary(aad) do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)
    {ct, tag} = :crypto.crypto_one_time_aead(@cipher, dek, nonce, plaintext, aad, true)
    {ct <> tag, nonce}
  end

  @spec decrypt(binary(), binary(), <<_::256>>) :: {:ok, binary()} | :error
  def decrypt(ct_with_tag, nonce, dek), do: decrypt(ct_with_tag, nonce, dek, <<>>)

  @spec decrypt(binary(), binary(), <<_::256>>, aad()) :: {:ok, binary()} | :error
  def decrypt(ct_with_tag, nonce, <<_::256>> = dek, aad)
      when is_binary(ct_with_tag) and byte_size(nonce) == @nonce_bytes and is_binary(aad) do
    size = byte_size(ct_with_tag) - @tag_bytes

    if size < 0 do
      :error
    else
      <<ct::binary-size(size), tag::binary-size(@tag_bytes)>> = ct_with_tag

      case :crypto.crypto_one_time_aead(@cipher, dek, nonce, ct, aad, tag, false) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> :error
      end
    end
  end

  def decrypt(_ct_with_tag, _nonce, <<_::256>>, _aad), do: :error
end
