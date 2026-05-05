defmodule Engram.Crypto.Envelope do
  @moduledoc """
  Stateless AES-256-GCM authenticated encryption.
  Ciphertext layout returned by encrypt/2 is `ciphertext || tag` (16-byte tag suffix).
  The nonce is returned separately; callers store it alongside ciphertext.
  """

  @cipher :aes_256_gcm
  @nonce_bytes 12
  @tag_bytes 16

  @spec encrypt(binary(), <<_::256>>) :: {binary(), binary()}
  def encrypt(plaintext, <<_::256>> = dek) when is_binary(plaintext) do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)
    {ct, tag} = :crypto.crypto_one_time_aead(@cipher, dek, nonce, plaintext, <<>>, true)
    {ct <> tag, nonce}
  end

  @spec decrypt(binary(), binary(), <<_::256>>) :: {:ok, binary()} | :error
  def decrypt(ct_with_tag, nonce, <<_::256>> = dek)
      when is_binary(ct_with_tag) and byte_size(nonce) == @nonce_bytes do
    size = byte_size(ct_with_tag) - @tag_bytes

    if size < 0 do
      :error
    else
      <<ct::binary-size(size), tag::binary-size(@tag_bytes)>> = ct_with_tag

      case :crypto.crypto_one_time_aead(@cipher, dek, nonce, ct, <<>>, tag, false) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> :error
      end
    end
  end

  def decrypt(_ct_with_tag, _nonce, <<_::256>>), do: :error
end
