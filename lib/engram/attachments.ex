defmodule Engram.Attachments do
  @moduledoc """
  Attachments context — CRUD for binary file attachments.
  All operations are tenant-scoped via Repo.with_tenant/2.

  Binary storage is delegated to the configured storage adapter
  (Database for BYTEA in Postgres, S3 for MinIO/Tigris).
  """

  import Ecto.Query

  alias Engram.Repo
  alias Engram.Attachments.Attachment
  alias Engram.Notes.PathSanitizer
  alias Engram.Storage

  @doc """
  Upserts an attachment. Decodes base64 content, detects MIME type, computes hash.
  Returns {:ok, attachment} or {:error, reason}.
  """
  def upsert_attachment(user, vault, attrs) do
    path = (attrs["path"] || attrs[:path]) |> PathSanitizer.sanitize()
    content_b64 = attrs["content_base64"] || attrs[:content_base64]
    mtime = attrs["mtime"] || attrs[:mtime]
    explicit_mime = attrs["mime_type"] || attrs[:mime_type]

    with {:ok, binary} <- decode_base64(content_b64),
         :ok <- validate_size(binary),
         {:ok, key, changeset_attrs} <- prepare_upload(user, vault, path, binary, mtime, explicit_mime),
         :ok <- store_external(key, binary, changeset_attrs.mime_type) do
      Repo.with_tenant(user.id, fn ->
        existing =
          Repo.one(
            from(a in Attachment,
              where: a.path == ^path and a.user_id == ^user.id and a.vault_id == ^vault.id
            )
          )

        case existing do
          nil ->
            %Attachment{}
            |> Attachment.changeset(changeset_attrs)
            |> Repo.insert()

          att ->
            att
            |> Attachment.changeset(changeset_attrs)
            |> Repo.update()
        end
      end)
      |> unwrap_tenant()
    end
  end

  @doc """
  Gets an attachment by path. Returns nil for soft-deleted.
  Fetches binary content from the configured storage backend.
  """
  def get_attachment(user, vault, path) do
    path = PathSanitizer.sanitize(path)

    result =
      Repo.with_tenant(user.id, fn ->
        Repo.one(
          from(a in Attachment,
            where:
              a.path == ^path and a.user_id == ^user.id and a.vault_id == ^vault.id and
                is_nil(a.deleted_at)
          )
        )
      end)
      |> unwrap_tenant()

    case result do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, %Attachment{content: content} = att} when not is_nil(content) ->
        # Content already in the row (Database adapter)
        {:ok, att}

      {:ok, %Attachment{} = att} ->
        # Content stored externally (S3 adapter) — fetch it
        key = att.storage_key || Storage.key(user.id, vault.id, path)

        case Storage.adapter().get(key) do
          {:ok, binary} ->
            {:ok, %{att | content: binary}}

          {:error, :not_found} ->
            # Live row with missing blob = storage corruption, not a normal 404
            require Logger
            Logger.error("Attachment blob missing for live row: id=#{att.id} key=#{key}")
            {:error, {:storage, :blob_missing}}

          {:error, reason} ->
            {:error, {:storage, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Soft-deletes an attachment. Idempotent — returns :ok even if already deleted or nonexistent.

  Ordering: soft-delete the DB row first (reversible), then delete the blob (permanent).
  If the blob delete fails, the row stays deleted and we log a warning — a zombie blob
  wastes storage but doesn't cause data loss, unlike the reverse (ghost row pointing to nothing).
  """
  def delete_attachment(user, vault, path) do
    path = PathSanitizer.sanitize(path)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.with_tenant(user.id, fn ->
      from(a in Attachment,
        where: a.path == ^path and a.user_id == ^user.id and a.vault_id == ^vault.id and is_nil(a.deleted_at)
      )
      |> Repo.update_all(set: [deleted_at: now, updated_at: now])
    end)

    # Best-effort blob cleanup — row is already soft-deleted so this is safe to retry later
    delete_external(Storage.adapter(), user.id, vault.id, path)

    :ok
  end

  defp delete_external(Storage.Database, _user_id, _vault_id, _path), do: :ok

  defp delete_external(backend, user_id, vault_id, path) do
    key = Storage.key(user_id, vault_id, path)

    case backend.delete(key) do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("Failed to delete blob key=#{key}: #{inspect(reason)} (row already soft-deleted)")
        :ok
    end
  end

  @doc """
  Lists attachment changes since a given timestamp. Returns metadata only (no content).
  """
  def list_changes(user, vault, since) do
    Repo.with_tenant(user.id, fn ->
      from(a in Attachment,
        where: a.user_id == ^user.id and a.vault_id == ^vault.id and a.updated_at >= ^since,
        order_by: [asc: a.updated_at],
        select: %{
          path: a.path,
          mime_type: a.mime_type,
          size_bytes: a.size_bytes,
          mtime: a.mtime,
          updated_at: a.updated_at,
          deleted_at: a.deleted_at
        }
      )
      |> Repo.all()
    end)
    |> unwrap_tenant()
  end

  @doc """
  Returns storage usage for a vault: total bytes and file count.
  """
  def storage_usage(user, vault) do
    Repo.with_tenant(user.id, fn ->
      from(a in Attachment,
        where: a.user_id == ^user.id and a.vault_id == ^vault.id and is_nil(a.deleted_at),
        select: %{
          used_bytes: type(coalesce(sum(a.size_bytes), 0), :integer),
          file_count: count(a.id)
        }
      )
      |> Repo.one()
    end)
    |> unwrap_tenant()
  end

  @doc """
  Returns storage usage for a user across all vaults: total bytes and file count.
  Used by the user-level /user/storage endpoint.
  """
  def storage_usage(user) do
    Repo.with_tenant(user.id, fn ->
      from(a in Attachment,
        where: a.user_id == ^user.id and is_nil(a.deleted_at),
        select: %{
          used_bytes: type(coalesce(sum(a.size_bytes), 0), :integer),
          file_count: count(a.id)
        }
      )
      |> Repo.one()
    end)
    |> unwrap_tenant()
  end

  # -- Private helpers --

  defp validate_size(binary) do
    if byte_size(binary) > Attachment.max_attachment_bytes(),
      do: {:error, :too_large},
      else: :ok
  end

  defp prepare_upload(user, vault, path, binary, mtime, explicit_mime) do
    mime = explicit_mime || detect_mime(path)
    hash = :crypto.hash(:md5, binary) |> Base.encode16(case: :lower)
    key = Storage.key(user.id, vault.id, path)
    backend = Storage.adapter()

    changeset_attrs =
      %{
        path: path,
        content_hash: hash,
        mime_type: mime,
        size_bytes: byte_size(binary),
        mtime: mtime,
        user_id: user.id,
        vault_id: vault.id,
        storage_key: key,
        deleted_at: nil
      }
      |> maybe_include_content(backend, binary)

    {:ok, key, changeset_attrs}
  end

  defp store_external(key, binary, mime) do
    backend = Storage.adapter()

    if backend == Storage.Database do
      :ok
    else
      case backend.put(key, binary, content_type: mime) do
        :ok -> :ok
        {:error, reason} -> {:error, {:storage, reason}}
      end
    end
  end

  defp maybe_include_content(attrs, Storage.Database, binary) do
    Map.put(attrs, :content, binary)
  end

  defp maybe_include_content(attrs, _s3_backend, _binary), do: attrs

  defp decode_base64(nil), do: {:error, :missing_content}

  defp decode_base64(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, :invalid_base64}
    end
  end

  defp detect_mime(path) do
    case Path.extname(path) |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".svg" -> "image/svg+xml"
      ".pdf" -> "application/pdf"
      ".mp3" -> "audio/mpeg"
      ".mp4" -> "video/mp4"
      ".wav" -> "audio/wav"
      ".txt" -> "text/plain"
      ".md" -> "text/markdown"
      ".json" -> "application/json"
      ".css" -> "text/css"
      ".js" -> "application/javascript"
      ".html" -> "text/html"
      ".zip" -> "application/zip"
      ".tar" -> "application/x-tar"
      ".gz" -> "application/gzip"
      _ -> "application/octet-stream"
    end
  end

  defp unwrap_tenant({:ok, {:ok, result}}), do: {:ok, result}
  defp unwrap_tenant({:ok, {:error, _} = err}), do: err
  defp unwrap_tenant({:ok, result}), do: {:ok, result}
  defp unwrap_tenant({:error, _} = err), do: err
end
