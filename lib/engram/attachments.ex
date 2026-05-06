defmodule Engram.Attachments do
  @moduledoc """
  Attachments context — CRUD for binary file attachments.
  All operations are tenant-scoped via Repo.with_tenant/2.

  Binary storage goes to the configured S3-compatible adapter
  (MinIO locally, Tigris in prod). Ciphertext only — every row
  is `encryption_version = 1` since A.5 (PR #62, 2026-05-02).
  """

  import Ecto.Query

  alias Engram.Repo
  alias Engram.Attachments.Attachment
  alias Engram.Notes.PathSanitizer
  alias Engram.Storage
  alias Engram.Crypto
  alias Engram.Crypto.Envelope

  @doc """
  Upserts an attachment. Decodes base64 content, detects MIME type, computes hash.
  Returns {:ok, attachment} or {:error, reason}.
  """
  def upsert_attachment(user, vault, attrs) do
    path = (attrs["path"] || attrs[:path]) |> PathSanitizer.sanitize()
    content_b64 = attrs["content_base64"] || attrs[:content_base64]
    mtime = attrs["mtime"] || attrs[:mtime]
    explicit_mime = attrs["mime_type"] || attrs[:mime_type]

    with {:ok, plaintext} <- decode_base64(content_b64),
         :ok <- validate_size(plaintext),
         {:ok, key, changeset_attrs, ciphertext} <-
           prepare_upload(user, vault, path, plaintext, mtime, explicit_mime),
         :ok <- store_external(key, ciphertext, changeset_attrs.mime_type) do
      path_hmac = changeset_attrs.path_hmac

      Repo.with_tenant(user.id, fn ->
        existing =
          Repo.one(
            from(a in Attachment,
              where:
                a.path_hmac == ^path_hmac and a.user_id == ^user.id and
                  a.vault_id == ^vault.id
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
      |> case do
        # Phase B.3: path is virtual — splice the plaintext we already have
        # onto the returned struct so callers can read att.path without a
        # second decrypt round-trip.
        {:ok, att} -> {:ok, %{att | path: path}}
        other -> other
      end
    end
  end

  @doc """
  Gets an attachment by path. Returns nil for soft-deleted.
  Fetches binary content from the configured storage backend.
  """
  def get_attachment(user, vault, path) do
    path = PathSanitizer.sanitize(path)
    user = fresh_user(user)

    result =
      with {:ok, filter_key} <- Crypto.dek_filter_key(user) do
        path_hmac = Crypto.hmac_field(filter_key, path)

        Repo.with_tenant(user.id, fn ->
          Repo.one(
            from(a in Attachment,
              where:
                a.path_hmac == ^path_hmac and a.user_id == ^user.id and
                  a.vault_id == ^vault.id and is_nil(a.deleted_at)
            )
          )
        end)
        |> unwrap_tenant()
      end

    case result do
      {:error, :no_dek} ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, %Attachment{} = att} ->
        {:ok, att} = Crypto.maybe_decrypt_attachment_fields(att, user)
        key = att.storage_key || Storage.key(user.id, vault.id, path)

        case Storage.adapter().get(key) do
          {:ok, ciphertext} ->
            decrypt(att, ciphertext, user)

          {:error, :not_found} ->
            # Live row with missing blob = storage corruption, not a normal 404
            require Logger

            Logger.error("Attachment blob missing for live row",
              attachment_id: att.id,
              storage_key: key
            )

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
    user = fresh_user(user)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Crypto.dek_filter_key(user) do
      {:ok, filter_key} ->
        path_hmac = Crypto.hmac_field(filter_key, path)

        Repo.with_tenant(user.id, fn ->
          from(a in Attachment,
            where:
              a.path_hmac == ^path_hmac and a.user_id == ^user.id and
                a.vault_id == ^vault.id and is_nil(a.deleted_at)
          )
          |> Repo.update_all(set: [deleted_at: now, updated_at: now])
        end)

        # Best-effort blob cleanup — row is already soft-deleted so this is safe to retry later
        delete_external(user.id, vault.id, path)

        :ok

      {:error, :no_dek} ->
        # No DEK = no attachments to delete; mirror get_attachment's defensive empty.
        :ok
    end
  end

  defp delete_external(user_id, vault_id, path) do
    key = Storage.key(user_id, vault_id, path)

    case Storage.adapter().delete(key) do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning("Failed to delete blob (row already soft-deleted)",
          storage_key: key,
          reason: inspect(reason)
        )

        :ok
    end
  end

  @doc """
  Lists attachment changes since a given timestamp. Returns metadata only (no content).
  """
  def list_changes(user, vault, since) do
    user = fresh_user(user)
    # Phase B.2.6 — load full Attachment rows so path can be decrypted from
    # ciphertext. The previous select-shape preview returned `a.path` directly
    # which won't survive B.3's column drop. Metadata-only output preserved.
    Repo.with_tenant(user.id, fn ->
      from(a in Attachment,
        where: a.user_id == ^user.id and a.vault_id == ^vault.id and a.updated_at >= ^since,
        order_by: [asc: a.updated_at]
      )
      |> Repo.all()
    end)
    |> unwrap_tenant()
    |> case do
      {:ok, atts} ->
        changes =
          Enum.map(atts, fn att ->
            {:ok, decrypted} = Crypto.maybe_decrypt_attachment_fields(att, user)

            %{
              path: decrypted.path,
              mime_type: decrypted.mime_type,
              size_bytes: decrypted.size_bytes,
              mtime: decrypted.mtime,
              updated_at: decrypted.updated_at,
              deleted_at: decrypted.deleted_at
            }
          end)

        {:ok, changes}

      err ->
        err
    end
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

  defp prepare_upload(user, vault, path, plaintext, mtime, explicit_mime) do
    mime = explicit_mime || detect_mime(path)
    key = Storage.key(user.id, vault.id, path)

    with {:ok, user} <- Crypto.ensure_user_dek(user),
         {:ok, dek} <- Crypto.get_dek(user),
         {:ok, content_key} <- Crypto.dek_content_hash_key(user) do
      hash = Crypto.hmac_content_hash(content_key, plaintext)
      {ciphertext, nonce} = Envelope.encrypt(plaintext, dek)
      {path_ct, path_n} = Envelope.encrypt(path, dek)
      {:ok, filter_key} = Crypto.dek_filter_key(user)

      attrs = %{
        content_hash: hash,
        mime_type: mime,
        size_bytes: byte_size(plaintext),
        mtime: mtime,
        user_id: user.id,
        vault_id: vault.id,
        storage_key: key,
        deleted_at: nil,
        encryption_version: 1,
        content_nonce: nonce,
        path_ciphertext: path_ct,
        path_nonce: path_n,
        path_hmac: Crypto.hmac_field(filter_key, path)
      }

      {:ok, key, attrs, ciphertext}
    end
  end

  defp store_external(key, binary, mime) do
    case Storage.adapter().put(key, binary, content_type: mime) do
      :ok -> :ok
      {:error, reason} -> {:error, {:storage, reason}}
    end
  end

  # Reload the user from DB if the in-memory struct doesn't reflect a DEK that
  # was provisioned by an earlier write (the writer's user struct doesn't
  # mutate the caller's). Read paths use this before any DEK derivation.
  defp fresh_user(%Engram.Accounts.User{encrypted_dek: nil} = user), do: Repo.reload!(user)
  defp fresh_user(%Engram.Accounts.User{} = user), do: user

  defp decrypt(%Attachment{content_nonce: nonce} = att, ciphertext, user) do
    with {:ok, dek} <- Crypto.get_dek(fresh_user(user)),
         {:ok, plaintext} <- Envelope.decrypt(ciphertext, nonce, dek) do
      {:ok, %{att | content: plaintext}}
    else
      :error -> {:error, :decrypt_failed}
      {:error, _} -> {:error, :decrypt_failed}
    end
  end

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
