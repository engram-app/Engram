defmodule Engram.Crypto.KeyProvider.Local do
  @moduledoc """
  KeyProvider implementation backed by an env-var master key.
  Wraps DEKs with AES-256-GCM using ENCRYPTION_MASTER_KEY.
  Supports one-key-back fallback for rotation via ENCRYPTION_MASTER_KEY_PREVIOUS.

  ## Wrap format (T3.4 / M2 + T3.6 / H1)

  Three coexisting shapes:

      v2 (T3.6, AAD-bound):
        <<0x02, 0x01, nonce::binary-size(12), ct::binary>>
        AAD on encrypt = "dek:v1:<user_id>" (pulled from ctx.user_id).

      v1 (T3.4, no AAD):
        <<0x01, 0x01, nonce::binary-size(12), ct::binary>>
        AAD = <<>>.

      legacy (pre-T3.4, no AAD, no header):
        <<nonce::binary-size(12), ct::binary>>

  `wrap_dek/2` always emits v2. `unwrap_dek/2` reads all three based on the
  leading byte and total `byte_size/1`:

      legacy: 12 (nonce) + 32 (DEK) + 16 (GCM tag) = 60 bytes, no header
      v1:      2 (header) + 60                     = 62 bytes, header 0x01
      v2:      2 (header) + 60                     = 62 bytes, header 0x02
  """

  @behaviour Engram.Crypto.KeyProvider

  alias Engram.Crypto.Config
  alias Engram.Crypto.Envelope

  require Logger

  # T3.4 / M2 + T3.6 / H1 — wrap-format constants.
  @wrap_version_v1 0x01
  @wrap_version_v2 0x02
  @alg_aes_256_gcm 0x01

  @impl true
  def name, do: :local

  @impl true
  def generate_dek, do: Engram.Crypto.KeyProvider.default_generate_dek()

  @impl true
  def wrap_dek(<<_::256>> = dek, ctx) do
    user_id = require_user_id!(ctx)
    aad = Engram.Crypto.aad_for_wrapped_dek(user_id)
    master = Config.local_master_key!()
    {ct, nonce} = Envelope.encrypt(dek, master, aad)

    {:ok, <<@wrap_version_v2, @alg_aes_256_gcm, nonce::binary-size(12), ct::binary>>}
  end

  @impl true
  def unwrap_dek(blob, ctx) when is_binary(blob) do
    case blob do
      <<@wrap_version_v2, @alg_aes_256_gcm, nonce::binary-size(12), ct::binary>>
      when byte_size(blob) == 62 ->
        # T3.6 — AAD-bound wrap. AAD = "dek:v1:<user_id>" pulled from ctx.
        user_id = require_user_id!(ctx)
        do_unwrap(ct, nonce, ctx, Engram.Crypto.aad_for_wrapped_dek(user_id))

      <<@wrap_version_v1, @alg_aes_256_gcm, nonce::binary-size(12), ct::binary>>
      when byte_size(blob) == 62 ->
        # T3.4 v1 — header present, no AAD.
        do_unwrap(ct, nonce, ctx, <<>>)

      <<nonce::binary-size(12), ct::binary>> when byte_size(blob) == 60 ->
        # Pre-T3.4 raw shape. No AAD.
        do_unwrap(ct, nonce, ctx, <<>>)

      _ ->
        {:error, :malformed_wrapped_blob}
    end
  end

  def unwrap_dek(_other, _ctx), do: {:error, :malformed_wrapped_blob}

  defp require_user_id!(ctx) do
    case Map.get(ctx, :user_id) do
      nil -> raise ArgumentError, "Local KeyProvider requires ctx.user_id for AAD binding"
      user_id -> user_id
    end
  end

  # T3.5 / M4 — `_PREVIOUS` fallback is gated on the user's `dek_version`
  # vs the configured `master_key_version`. A user whose dek_version is
  # at-or-above the current master generation has been rotated already;
  # if its blob fails to decrypt with the current key, that is a real
  # error — falling through to `_PREVIOUS` would silently mask a wrong-
  # key boot or a rotation regression.
  #
  # Telemetry `[:engram, :crypto, :previous_fallback_hit]` fires
  # whenever the fallback is consulted (whether it rescues or not), so
  # operators can watch the count drop to zero post-rotation.
  defp do_unwrap(ct, nonce, ctx, aad) do
    current = Config.local_master_key!()

    case Envelope.decrypt(ct, nonce, current, aad) do
      {:ok, <<_::256>> = dek} ->
        {:ok, dek}

      :error ->
        try_previous_fallback(ct, nonce, ctx, aad)
    end
  end

  defp try_previous_fallback(ct, nonce, ctx, aad) do
    if previous_fallback_allowed?(ctx) do
      case Config.local_master_key_previous() do
        nil ->
          emit_fallback_telemetry(ctx, :no_previous_configured)
          {:error, :invalid_wrapping}

        prev ->
          result =
            case Envelope.decrypt(ct, nonce, prev, aad) do
              {:ok, <<_::256>> = dek} -> {:ok, dek}
              :error -> {:error, :invalid_wrapping}
            end

          emit_fallback_telemetry(ctx, result)
          result
      end
    else
      emit_fallback_telemetry(ctx, :gated_by_dek_version)
      {:error, :invalid_wrapping}
    end
  end

  defp previous_fallback_allowed?(ctx) do
    if Map.get(ctx, :disable_previous_fallback) == true do
      false
    else
      dek_version = Map.get(ctx, :dek_version)
      master_key_version = Map.get(ctx, :master_key_version) || Config.master_key_version()

      is_nil(dek_version) or dek_version < master_key_version
    end
  end

  defp emit_fallback_telemetry(ctx, outcome) do
    classified = classify_outcome(outcome)

    # T3-audit M5 — a user whose DEK cannot be unwrapped by EITHER the
    # current master key OR the configured `_PREVIOUS` is in catastrophic
    # state: their data is unrecoverable. Telemetry-only signaling (which
    # depends on H2's metric registration AND a scrape pipeline) is not
    # enough — Logger.error guarantees visibility in any standard log
    # pipeline so operators page on the failure.
    if classified == :failed do
      Logger.error(
        "dek unwrap failed under both current and _PREVIOUS master keys: " <>
          "user_id=#{inspect(Map.get(ctx, :user_id))}",
        category: :crypto_unwrap
      )
    end

    :telemetry.execute(
      [:engram, :crypto, :previous_fallback_hit],
      %{count: 1},
      %{
        user_id: Map.get(ctx, :user_id),
        dek_version: Map.get(ctx, :dek_version),
        master_key_version: Map.get(ctx, :master_key_version) || Config.master_key_version(),
        # T3-audit M1 — `:status` matches rotate.user / aad_rebind.user
        # metadata. Single, consistent dispatch tag across crypto events.
        status: classified
      }
    )
  end

  defp classify_outcome({:ok, _}), do: :rescued
  defp classify_outcome({:error, :invalid_wrapping}), do: :failed
  defp classify_outcome(:no_previous_configured), do: :no_previous_configured
  defp classify_outcome(:gated_by_dek_version), do: :gated_by_dek_version

  @impl true
  def supports_async_workers?, do: true

  @impl true
  def rotate_wrapping(wrapped, ctx) do
    with {:ok, dek} <- unwrap_dek(wrapped, ctx) do
      wrap_dek(dek, ctx)
    end
  end

  @impl true
  def rotate_dek(_old_wrapped, ctx) do
    # T3.7 — generate a brand-new DEK (entropy from the same source as
    # `generate_dek/0`) and wrap it under the user's AAD-bound v2 format.
    # The `_old_wrapped` argument is unused for Local: the orchestrator
    # already holds the unwrapped old DEK in process heap when it calls
    # this. The argument is reserved for AwsKms-class providers that
    # want to do the rotate atomically server-side.
    new_dek = generate_dek()
    {:ok, new_wrapped} = wrap_dek(new_dek, ctx)
    {:ok, new_wrapped, new_dek}
  end

  @impl true
  def boot_check, do: :ok

  @impl true
  def unwrap_dek_no_fallback(blob, %{user_id: uid}) when is_binary(blob) do
    unwrap_dek_current_only(blob, user_id: uid)
  end

  @doc """
  T3.5.5 / M3 — current-master-key-only unwrap, for `BootCanary`. Bypasses
  `_PREVIOUS` fallback so a misconfigured `ENCRYPTION_MASTER_KEY` cannot
  be silently rescued by `_PREVIOUS` during boot verification. Distinct
  from `unwrap_dek/2` so production callers cannot accidentally adopt
  this mode and break legitimate rotation reads.
  """
  @spec unwrap_dek_current_only(binary(), keyword()) ::
          {:ok, <<_::256>>}
          | {:error, :invalid_wrapping | :malformed_wrapped_blob | :missing_user_id_for_aad}
  def unwrap_dek_current_only(blob, opts \\ []) when is_binary(blob) do
    current = Config.local_master_key!()
    user_id = Keyword.get(opts, :user_id)

    case blob do
      <<@wrap_version_v2, @alg_aes_256_gcm, nonce::binary-size(12), ct::binary>>
      when byte_size(blob) == 62 ->
        case user_id do
          nil ->
            {:error, :missing_user_id_for_aad}

          uid ->
            decrypt_or_invalid(
              ct,
              nonce,
              current,
              Engram.Crypto.aad_for_wrapped_dek(uid)
            )
        end

      <<@wrap_version_v1, @alg_aes_256_gcm, nonce::binary-size(12), ct::binary>>
      when byte_size(blob) == 62 ->
        decrypt_or_invalid(ct, nonce, current, <<>>)

      <<nonce::binary-size(12), ct::binary>> when byte_size(blob) == 60 ->
        decrypt_or_invalid(ct, nonce, current, <<>>)

      _ ->
        {:error, :malformed_wrapped_blob}
    end
  end

  defp decrypt_or_invalid(ct, nonce, key, aad) do
    case Envelope.decrypt(ct, nonce, key, aad) do
      {:ok, <<_::256>> = dek} -> {:ok, dek}
      :error -> {:error, :invalid_wrapping}
    end
  end
end
