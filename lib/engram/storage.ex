defmodule Engram.Storage do
  @moduledoc """
  Behaviour for file storage backends (S3, database, etc.).
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

  @doc "Returns the configured storage adapter module."
  def adapter, do: Application.get_env(:engram, :storage, __MODULE__.Database)

  @doc "Build a storage key from user_id, vault_id, and attachment path."
  def key(user_id, vault_id, path)
      when is_integer(user_id) and is_integer(vault_id) and is_binary(path) and path != "" do
    "#{user_id}/#{vault_id}/#{path}"
  end
end
