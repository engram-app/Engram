defmodule Engram.Storage.S3 do
  @moduledoc """
  S3-compatible storage adapter. Works with MinIO (local) and Fly Tigris (prod).
  """

  @behaviour Engram.Storage

  defp bucket, do: Application.fetch_env!(:engram, :storage_bucket)

  @impl true
  def put(key, binary, opts \\ []) do
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")

    case ExAws.S3.put_object(bucket(), key, binary, content_type: content_type)
         |> ExAws.request() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get(key) do
    case ExAws.S3.get_object(bucket(), key) |> ExAws.request() do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, {:http_error, 404, _}} -> {:error, :not_found}
      {:error, {:http_error, 404}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    case ExAws.S3.delete_object(bucket(), key) |> ExAws.request() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete_prefix(prefix) when is_binary(prefix) and prefix != "" do
    case ExAws.S3.list_objects(bucket(), prefix: prefix) |> ExAws.request() do
      {:ok, %{body: %{contents: contents}}} ->
        keys = Enum.map(contents, & &1.key)
        delete_many(keys)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_many([]), do: {:ok, 0}

  defp delete_many(keys) do
    case ExAws.S3.delete_multiple_objects(bucket(), keys) |> ExAws.request() do
      {:ok, _} -> {:ok, length(keys)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_user_prefixes do
    case ExAws.S3.list_objects(bucket(), delimiter: "/") |> ExAws.request() do
      {:ok, %{body: %{common_prefixes: prefixes}}} ->
        ids =
          prefixes
          |> Enum.map(& &1.prefix)
          |> Enum.flat_map(&parse_user_id_from_prefix/1)

        {:ok, ids}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_user_id_from_prefix(prefix) do
    case Integer.parse(String.trim_trailing(prefix, "/")) do
      {id, ""} -> [id]
      _ -> []
    end
  end

  @impl true
  def selfhost?, do: false

  @impl true
  def sign_url(key, opts) when is_binary(key) and is_list(opts) do
    ttl = Keyword.fetch!(opts, :ttl)

    {:ok, url} =
      ExAws.Config.new(:s3)
      |> ExAws.S3.presigned_url(:get, bucket(), key, expires_in: ttl)

    url
  end

  @impl true
  def exists?(key) do
    case ExAws.S3.head_object(bucket(), key) |> ExAws.request() do
      {:ok, _} ->
        true

      {:error, {:http_error, 404, _}} ->
        false

      {:error, {:http_error, 404}} ->
        false

      {:error, reason} ->
        require Logger
        Logger.error("S3.exists? failed", storage_key: key, reason: inspect(reason))
        false
    end
  end
end
