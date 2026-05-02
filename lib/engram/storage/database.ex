defmodule Engram.Storage.Database do
  @moduledoc """
  Database storage adapter — stores binary content in the attachments table (BYTEA).
  Provides backward compatibility with the original storage model.

  Key format: "user_id/vault_id/path" — parsed via String.split(key, "/", parts: 3).
  """

  @behaviour Engram.Storage

  import Ecto.Query

  alias Engram.Repo
  alias Engram.Attachments.Attachment

  @impl true
  def put(key, binary, opts \\ []) do
    {user_id, vault_id, path} = parse_key(key)
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")
    hash = :crypto.hash(:md5, binary) |> Base.encode16(case: :lower)

    Repo.with_tenant(user_id, fn ->
      existing =
        Repo.one(
          from(a in Attachment,
            where: a.path == ^path and a.user_id == ^user_id and a.vault_id == ^vault_id
          )
        )

      attrs = %{
        path: path,
        content: binary,
        content_hash: hash,
        mime_type: content_type,
        size_bytes: byte_size(binary),
        user_id: user_id,
        vault_id: vault_id,
        deleted_at: nil
      }

      case existing do
        nil ->
          %Attachment{}
          |> Attachment.changeset(attrs)
          |> Repo.insert()

        att ->
          att
          |> Attachment.changeset(attrs)
          |> Repo.update()
      end
    end)
    |> case do
      {:ok, {:ok, _}} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get(key) do
    {user_id, vault_id, path} = parse_key(key)

    Repo.with_tenant(user_id, fn ->
      Repo.one(
        from(a in Attachment,
          where:
            a.path == ^path and a.user_id == ^user_id and a.vault_id == ^vault_id and
              is_nil(a.deleted_at),
          select: a.content
        )
      )
    end)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    {user_id, vault_id, path} = parse_key(key)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.with_tenant(user_id, fn ->
      from(a in Attachment,
        where:
          a.path == ^path and a.user_id == ^user_id and a.vault_id == ^vault_id and
            is_nil(a.deleted_at)
      )
      |> Repo.update_all(set: [deleted_at: now, updated_at: now])
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def exists?(key) do
    {user_id, vault_id, path} = parse_key(key)

    Repo.with_tenant(user_id, fn ->
      Repo.exists?(
        from(a in Attachment,
          where:
            a.path == ^path and a.user_id == ^user_id and a.vault_id == ^vault_id and
              is_nil(a.deleted_at)
        )
      )
    end)
    |> case do
      {:ok, result} ->
        result

      {:error, reason} ->
        require Logger
        Logger.error("Database.exists? failed for key=#{key}: #{inspect(reason)}")
        false
    end
  end

  defp parse_key(key) when is_binary(key) do
    case String.split(key, "/", parts: 3) do
      [user_id_str, vault_id_str, path] when path != "" ->
        {String.to_integer(user_id_str), String.to_integer(vault_id_str), path}

      _ ->
        raise ArgumentError,
              "invalid storage key format (expected \"user_id/vault_id/path\"): #{inspect(key)}"
    end
  end
end
