defmodule Engram.Storage do
  @moduledoc """
  Behaviour for S3-compatible file storage backends (MinIO local, Tigris prod).
  All keys are scoped by user_id and vault_id prefix: "user_id/vault_id/path".
  """

  @callback put(key :: String.t(), binary :: binary(), opts :: keyword()) ::
              :ok | {:error, term()}

  @callback get(key :: String.t()) ::
              {:ok, binary()} | {:error, :not_found | term()}

  @callback delete(key :: String.t()) ::
              :ok | {:error, term()}

  @callback exists?(key :: String.t()) ::
              boolean()

  @callback delete_prefix(prefix :: String.t()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Enumerates the top-level user_id prefixes in the bucket (one per active
  user). Used by `Engram.Workers.OrphanSweep` to diff against the live
  users table without listing every blob.
  """
  @callback list_user_prefixes() ::
              {:ok, [non_neg_integer()]} | {:error, term()}

  @doc """
  Whether this adapter is a self-host backend that cannot mint pre-signed
  download URLs (Postgres `bytea`; anything that requires the application
  process to stream bytes itself). Used by `Engram.Accounts.Export` to
  decide between handing the client a URL vs streaming via the controller.

  The S3 adapter returns `false` even when fronted by self-host MinIO —
  presigning works there. Only adapters that genuinely cannot presign
  (`Database`, in-memory test stub) return `true`.
  """
  @callback selfhost?() :: boolean()

  @doc """
  Mint a short-lived signed download URL for `key`. Required `:ttl` option
  (seconds) bounds the URL's lifetime. Only callable on adapters where
  `selfhost?/0` returns `false`; selfhost adapters raise.
  """
  @callback sign_url(key :: String.t(), opts :: keyword()) :: String.t()

  @doc "Returns the configured storage adapter module."
  def adapter, do: Application.get_env(:engram, :storage, __MODULE__.S3)

  @doc "Build a storage key from user_id, vault_id, and attachment path."
  def key(user_id, vault_id, path)
      when is_integer(user_id) and is_integer(vault_id) and is_binary(path) and path != "" do
    "#{user_id}/#{vault_id}/#{path}"
  end
end
