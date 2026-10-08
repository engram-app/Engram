defmodule Engram.CryptoOracle do
  @moduledoc false
  # The `:crypto` envelope that `Engram.Crypto.Envelope` ran on before the
  # Rust engine (#1872), kept as the format-0 oracle: same key, nonce, AAD
  # and plaintext must give the same `ciphertext || tag`, byte for byte.

  def encrypt_with_nonce(plaintext, key, aad, nonce) do
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, aad, true)
    ct <> tag
  end

  def encrypt(plaintext, key, aad) do
    nonce = :crypto.strong_rand_bytes(12)
    {encrypt_with_nonce(plaintext, key, aad, nonce), nonce}
  end

  def decrypt(ct_with_tag, nonce, key, aad) when byte_size(ct_with_tag) >= 16 do
    size = byte_size(ct_with_tag) - 16
    <<ct::binary-size(size), tag::binary-size(16)>> = ct_with_tag

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ct, aad, tag, false) do
      plain when is_binary(plain) -> {:ok, plain}
      :error -> :error
    end
  end

  def decrypt(_ct, _nonce, _key, _aad), do: :error
end
