defmodule Engram.Crypto.KeyProvider.AwsKms do
  @moduledoc """
  KeyProvider implementation backed by AWS KMS. Wraps per-user DEKs via
  `kms:Encrypt`/`Decrypt`/`ReEncrypt`, binding `user_id` via KMS
  `EncryptionContext` (authenticated additional data).

  Wrapped blob format:

      <<0xAA, 0x01, kms_ciphertext::binary>>

  `0xAA` is the provider tag (does not collide with Local's `0x01`/`0x02`).
  `0x01` is the payload version for KMS+EncryptionContext-bound ciphertext.

  KMS calls dispatch through the `Engram.AwsKms` Mox seam (resolved from
  `:engram, :aws_kms_client`).
  """

  @behaviour Engram.Crypto.KeyProvider

  @provider_tag 0xAA
  @payload_v1 0x01

  @impl true
  def name, do: :aws_kms

  @impl true
  def generate_dek, do: Engram.Crypto.KeyProvider.default_generate_dek()

  @impl true
  def supports_async_workers?, do: true

  @impl true
  def wrap_dek(<<_::256>> = dek, %{user_id: uid}) do
    case aws_kms().encrypt(dek, encryption_context(uid)) do
      {:ok, ct} -> {:ok, <<@provider_tag, @payload_v1, ct::binary>>}
      {:error, reason} -> {:error, {:kms_encrypt_failed, reason}}
    end
  end

  @impl true
  def unwrap_dek(<<@provider_tag, @payload_v1, ct::binary>>, %{user_id: uid}) do
    case aws_kms().decrypt(ct, encryption_context(uid)) do
      {:ok, <<_::256>> = dek} -> {:ok, dek}
      {:ok, _wrong_size} -> {:error, :malformed_wrapped_blob}
      {:error, :access_denied} -> {:error, :kms_access_denied}
      {:error, :throttled} -> {:error, :kms_throttled}
      {:error, :context_mismatch} -> {:error, :invalid_wrapping}
      {:error, :key_not_found} -> {:error, :kms_key_not_found}
      {:error, reason} -> {:error, {:kms_decrypt_failed, reason}}
    end
  end

  def unwrap_dek(_other, _ctx), do: {:error, :malformed_wrapped_blob}

  @impl true
  def rotate_wrapping(<<@provider_tag, @payload_v1, ct::binary>>, %{user_id: uid}) do
    ctx = encryption_context(uid)

    case aws_kms().re_encrypt(ct, ctx, ctx) do
      {:ok, new_ct} -> {:ok, <<@provider_tag, @payload_v1, new_ct::binary>>}
      {:error, reason} -> {:error, {:kms_reencrypt_failed, reason}}
    end
  end

  def rotate_wrapping(_other, _ctx), do: {:error, :malformed_wrapped_blob}

  @impl true
  def boot_check, do: aws_kms().describe_key()

  @impl true
  def unwrap_dek_no_fallback(<<@provider_tag, @payload_v1, _::binary>> = blob, ctx),
    do: unwrap_dek(blob, ctx)

  def unwrap_dek_no_fallback(_other, _ctx), do: {:error, :malformed_wrapped_blob}

  @impl true
  def rotate_dek(_old, %{user_id: _} = ctx) do
    dek = generate_dek()
    with {:ok, wrapped} <- wrap_dek(dek, ctx), do: {:ok, wrapped, dek}
  end

  @doc "KMS EncryptionContext bound on every wrap/unwrap call."
  @spec encryption_context(integer() | atom() | String.t()) :: %{String.t() => String.t()}
  def encryption_context(uid),
    do: %{"user_id" => to_string(uid), "purpose" => "dek_wrap"}

  defp aws_kms, do: Application.fetch_env!(:engram, :aws_kms_client)
end
