defmodule Engram.AwsKms do
  @moduledoc """
  Mox seam over AWS KMS. The production impl is `Engram.AwsKms.ExAws`;
  tests stub `Engram.AwsKmsMock`. Resolved via `:engram, :aws_kms_client`
  in app config.

  All callbacks return atom-classified errors so callers can pattern-match
  without parsing AWS error strings.
  """

  @type ciphertext :: binary()
  @type plaintext :: binary()
  @type enc_ctx :: %{optional(String.t()) => String.t()}
  @type error_class ::
          :access_denied
          | :throttled
          | :context_mismatch
          | :key_not_found
          | :network_error
          | {:aws, code :: String.t(), message :: String.t()}

  @callback encrypt(plaintext(), enc_ctx()) :: {:ok, ciphertext()} | {:error, error_class()}
  @callback decrypt(ciphertext(), enc_ctx()) :: {:ok, plaintext()} | {:error, error_class()}
  @callback re_encrypt(ciphertext(), enc_ctx(), enc_ctx()) ::
              {:ok, ciphertext()} | {:error, error_class()}
  @callback describe_key() :: :ok | {:error, error_class()}
end
