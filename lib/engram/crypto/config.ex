defmodule Engram.Crypto.Config do
  @moduledoc """
  Validates encryption configuration at application boot.
  Raises with actionable messages if misconfigured.
  """

  @valid_providers [
    Engram.Crypto.KeyProvider.Local,
    Engram.Crypto.KeyProvider.AwsKms
    # Future: Engram.Crypto.KeyProvider.Passphrase
  ]

  @spec validate!() :: :ok
  def validate! do
    provider = Application.get_env(:engram, :key_provider)

    cond do
      is_nil(provider) ->
        raise "key_provider is not configured — set :engram, :key_provider in config"

      provider not in @valid_providers ->
        raise "unknown key_provider #{inspect(provider)}; valid options: #{inspect(@valid_providers)}"

      true ->
        :ok
    end

    if provider == Engram.Crypto.KeyProvider.Local do
      validate_local_master_key!()
    end

    if provider == Engram.Crypto.KeyProvider.AwsKms do
      validate_aws_kms!()
    end

    :ok
  end

  @doc "Returns the decoded 32-byte master key for the Local provider."
  @spec local_master_key!() :: <<_::256>>
  def local_master_key! do
    raw = Application.get_env(:engram, :encryption_master_key)
    decode_master_key!(raw, "ENCRYPTION_MASTER_KEY")
  end

  @doc "Returns the decoded 32-byte previous master key if set, else nil. For rotation."
  @spec local_master_key_previous() :: <<_::256>> | nil
  def local_master_key_previous do
    case Application.get_env(:engram, :encryption_master_key_previous) do
      nil -> nil
      "" -> nil
      raw -> decode_master_key!(raw, "ENCRYPTION_MASTER_KEY_PREVIOUS")
    end
  end

  @doc """
  T3.5 / M4 — current master-key generation. Bumped after each
  rotation completes (via `ENCRYPTION_MASTER_KEY_VERSION` env or app
  config). Used by `Engram.Crypto.get_dek/1` to gate the `_PREVIOUS`
  fallback: a user whose `dek_version >= master_key_version` has
  already been rotated and MUST decrypt with the current key — falling
  back to `_PREVIOUS` for such a user signals a rotation regression
  (or a wrong-key boot) that should fail loudly, not silently rescue.

  Default is `1` — the implicit version for any pre-T3.5 deployment.
  """
  @spec master_key_version() :: pos_integer()
  def master_key_version do
    case Application.get_env(:engram, :encryption_master_key_version, 1) do
      v when is_integer(v) and v >= 1 -> v
      raw when is_binary(raw) -> String.to_integer(raw)
    end
  end

  defp validate_local_master_key! do
    _ = local_master_key!()
    :ok
  end

  defp validate_aws_kms! do
    key_id = Application.get_env(:engram, :aws_kms_key_id)
    region = Application.get_env(:engram, :aws_kms_region)
    access = Application.get_env(:ex_aws, :access_key_id)
    secret = Application.get_env(:ex_aws, :secret_access_key)

    cond do
      is_nil(key_id) or key_id == "" ->
        raise "AWS_KMS_KEY_ID is required when KEY_PROVIDER=aws_kms"

      not valid_key_id?(key_id) ->
        raise "AWS_KMS_KEY_ID must be an ARN (arn:aws:kms:...) or an alias (alias/...)"

      is_nil(region) or region == "" ->
        raise "AWS_REGION is required when KEY_PROVIDER=aws_kms"

      is_nil(access) or access == "" ->
        raise "AWS_ACCESS_KEY_ID is required when KEY_PROVIDER=aws_kms"

      is_nil(secret) or secret == "" ->
        raise "AWS_SECRET_ACCESS_KEY is required when KEY_PROVIDER=aws_kms"

      true ->
        :ok
    end
  end

  defp valid_key_id?(id) when is_binary(id) do
    String.starts_with?(id, "arn:aws:kms:") or String.starts_with?(id, "alias/")
  end

  defp valid_key_id?(_), do: false

  defp decode_master_key!(nil, name), do: raise("#{name} is required when KEY_PROVIDER=local")
  defp decode_master_key!("", name), do: raise("#{name} is required when KEY_PROVIDER=local")

  defp decode_master_key!(raw, name) when is_binary(raw) do
    case Base.decode64(raw) do
      {:ok, <<_::256>> = key} ->
        key

      {:ok, other} ->
        raise "#{name} must decode to 32 bytes; got #{byte_size(other)} bytes"

      :error ->
        raise "#{name} must be valid base64"
    end
  end
end
