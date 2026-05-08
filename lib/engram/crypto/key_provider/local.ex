defmodule Engram.Crypto.KeyProvider.Local do
  @moduledoc """
  KeyProvider implementation backed by an env-var master key.
  Wraps DEKs with AES-256-GCM using ENCRYPTION_MASTER_KEY.
  Supports one-key-back fallback for rotation via ENCRYPTION_MASTER_KEY_PREVIOUS.

  ## Wrap format (T3.4 / M2)

  New writes use a 2-byte header before nonce + ciphertext:

      <<0x01, 0x01, nonce::binary-size(12), ct::binary>>
      # ^^^   ^^^   ^^^^^^^^^^^^^^^^^^^^   ^^^^^^^^^^^
      #  |     |    |                       AES-GCM ct + 16-byte tag
      #  |     |    fresh per-encrypt nonce
      #  |     algorithm id (0x01 = AES-256-GCM)
      #  wrap-format version (0x01 = first header-bearing version)

  Pre-T3.4 rows in DB carry the legacy raw shape `<<nonce::12, ct::binary>>`
  (no header). `unwrap_dek/2` reads both shapes — the version-byte form
  matches first, and a 60-byte raw shape falls through to the legacy
  clause. Disambiguation is by total `byte_size/1`:

      legacy: 12 (nonce) + 32 (DEK) + 16 (GCM tag) = 60 bytes
      v1:      2 (header) + 60                     = 62 bytes
  """

  @behaviour Engram.Crypto.KeyProvider

  alias Engram.Crypto.Envelope
  alias Engram.Crypto.Config

  # T3.4 / M2 — wrap-format constants.
  @wrap_version_v1 0x01
  @alg_aes_256_gcm 0x01

  @impl true
  def name, do: :local

  @impl true
  def generate_dek, do: Engram.Crypto.KeyProvider.default_generate_dek()

  @impl true
  def wrap_dek(<<_::256>> = dek, _ctx) do
    master = Config.local_master_key!()
    {ct, nonce} = Envelope.encrypt(dek, master)

    {:ok,
     <<@wrap_version_v1, @alg_aes_256_gcm, nonce::binary-size(12), ct::binary>>}
  end

  @impl true
  def unwrap_dek(blob, ctx) when is_binary(blob) do
    case blob do
      <<@wrap_version_v1, @alg_aes_256_gcm, nonce::binary-size(12), ct::binary>>
      when byte_size(blob) == 62 ->
        do_unwrap(ct, nonce, ctx)

      <<nonce::binary-size(12), ct::binary>> when byte_size(blob) == 60 ->
        # T3.4 — legacy pre-header shape. Kept for backward read so the
        # wrap-version rollout does not require a backfill pass.
        do_unwrap(ct, nonce, ctx)

      _ ->
        {:error, :malformed_wrapped_blob}
    end
  end

  def unwrap_dek(_other, _ctx), do: {:error, :malformed_wrapped_blob}

  defp do_unwrap(ct, nonce, _ctx) do
    current = Config.local_master_key!()

    case Envelope.decrypt(ct, nonce, current) do
      {:ok, <<_::256>> = dek} ->
        {:ok, dek}

      :error ->
        case Config.local_master_key_previous() do
          nil ->
            {:error, :invalid_wrapping}

          prev ->
            case Envelope.decrypt(ct, nonce, prev) do
              {:ok, <<_::256>> = dek} -> {:ok, dek}
              :error -> {:error, :invalid_wrapping}
            end
        end
    end
  end

  @impl true
  def supports_async_workers?, do: true

  @impl true
  def rotate_wrapping(wrapped, ctx) do
    with {:ok, dek} <- unwrap_dek(wrapped, ctx) do
      wrap_dek(dek, ctx)
    end
  end
end
