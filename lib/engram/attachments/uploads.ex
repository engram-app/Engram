defmodule Engram.Attachments.Uploads do
  @moduledoc """
  Chunked (multipart) attachment uploads: start a session, PUT parts in any
  order (a re-PUT replaces the part), then complete into a live attachment in
  content format v2 (`Engram.Attachments.SegmentedCipher`).

  Each part is sealed as one segment under a per-file key before it reaches
  storage, so no plaintext is ever stored. Nothing counts against the quota
  until `complete/3`, which re-checks it against live usage under the same
  per-path lock single-request uploads take (`Attachments.commit_row/6`).

  The blob key is per upload (`Storage.object_key/3` on the upload id), never
  shared with the row it replaces, so a refused or abandoned upload can be
  dropped without touching the live blob.
  """

  import Ecto.Query

  alias Engram.Attachments
  alias Engram.Attachments.Attachment
  alias Engram.Attachments.SegmentedCipher
  alias Engram.Attachments.Upload
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Crypto.RotationGate
  alias Engram.Links
  alias Engram.Logger.Metadata
  alias Engram.Notes.PathSanitizer
  alias Engram.Repo
  alias Engram.Storage
  alias Engram.Storage.MimeWhitelist

  require Logger

  # 8 MiB: above S3's 5 MiB non-final-part minimum, small enough to retry cheaply.
  @part_size 8_388_608

  # No @spec: literal body (dialyzer contract_supertype; same as Envelope.tag_bytes/0).
  def part_size, do: @part_size

  @doc "Composable tenant scope for upload sessions (see `Attachments.scoped/2`)."
  @spec scoped(map(), map() | term()) :: Ecto.Query.t()
  def scoped(user, %{id: vault_id}), do: scoped(user, vault_id)

  def scoped(user, vault_id),
    do: from(u in Upload, where: u.user_id == ^user.id and u.vault_id == ^vault_id)

  @request_types %{path: :string, size_bytes: :integer, mtime: :float, mime_type: :string}

  @doc """
  Opens an upload session for a file of `size_bytes`. Refuses up front what
  `complete/3` would refuse, so a client never sends parts for nothing.
  """
  @spec start(map(), map(), map()) ::
          {:ok, Upload.t()}
          | {:error,
             {:extension_not_allowed, String.t()}
             | :invalid_mime
             | {:too_large, integer()}
             | {:storage_cap_reached, integer(), integer()}
             | :multipart_unsupported
             | :rotation_in_progress
             | {:storage, term()}
             | Ecto.Changeset.t()}
  def start(user, vault, attrs) do
    with :ok <- Attachments.rotation_gate(user),
         {:ok, req} <- cast_request(attrs),
         path = PathSanitizer.sanitize(req.path),
         mime = req[:mime_type] || MimeWhitelist.detect_mime(path),
         :ok <- MimeWhitelist.check(mime, path),
         :ok <- Attachments.validate_size(req.size_bytes, user),
         true <- Storage.adapter().multipart?() || {:error, :multipart_unsupported},
         {:ok, user} <- Crypto.ensure_user_dek(user),
         # Before any key is derived; re-checked at the insert.
         dek_version = RotationGate.dek_version(user.id),
         {:ok, filter_key} <- Crypto.dek_filter_key(user),
         {:ok, dek} <- Crypto.get_dek(user),
         path_hmac = Crypto.hmac_field(filter_key, path),
         existing = Attachments.fetch_existing(user, vault.id, path_hmac),
         :ok <- Attachments.validate_storage_cap(user, existing, req.size_bytes) do
      id = Ecto.UUID.generate()
      att_id = if existing, do: existing.id, else: Ecto.UUID.generate()
      {wrapped, key_nonce} = SegmentedCipher.wrap_key(SegmentedCipher.new_file_key(), dek, att_id)
      {path_ct, path_n} = Envelope.encrypt(path, dek, path_aad(id))
      storage_key = Storage.object_key(user.id, vault.id, id)

      with {:ok, s3_upload_id} <- start_multipart(storage_key) do
        %Upload{id: id}
        |> Upload.changeset(%{
          user_id: user.id,
          vault_id: vault.id,
          attachment_id: att_id,
          path_hmac: path_hmac,
          path_ciphertext: path_ct,
          path_nonce: path_n,
          mime_type: mime,
          size_bytes: req.size_bytes,
          mtime: req[:mtime],
          part_size: @part_size,
          part_count: div(req.size_bytes + @part_size - 1, @part_size),
          storage_key: storage_key,
          s3_upload_id: s3_upload_id,
          wrapped_file_key: wrapped,
          file_key_nonce: key_nonce,
          dek_version: dek_version
        })
        # Gated again inside the insert's transaction (share-locks the user
        # row): a session committed after rotation swept the sessions would
        # keep a file key and path under the retiring DEK.
        |> then(fn changeset ->
          Repo.with_tenant(user.id, fn ->
            with :ok <- Attachments.rotation_gate(user, dek_version),
                 do: Repo.insert(changeset)
          end)
        end)
        |> unwrap()
        |> case do
          {:ok, upload} ->
            {:ok, upload}

          {:error, _} = err ->
            # Best-effort; abort_storage logs its own failure.
            _ = abort_storage(storage_key, s3_upload_id)
            err
        end
      end
    end
  end

  @doc """
  Seals and stores part `n` (1-based). Its size must be exactly `part_size`,
  or the remainder for the final part; both are checked before any storage
  call. Re-sending a part replaces it.
  """
  @spec put_part(map(), map(), Ecto.UUID.t(), integer(), binary()) ::
          {:ok, %{part: pos_integer()}}
          | {:error,
             :not_found
             | :bad_part_number
             | :bad_part_size
             | :rotation_in_progress
             | {:storage, term()}}
  def put_part(user, vault, upload_id, n, bytes) when is_binary(bytes) do
    user = Crypto.fresh_user(user)

    with :ok <- Attachments.rotation_gate(user),
         {:ok, up} <- fetch(user, vault, upload_id),
         :ok <- check_part(up, n, byte_size(bytes)),
         {:ok, file_key} <- file_key(user, up, up.attachment_id),
         sealed = SegmentedCipher.seal_segment(bytes, file_key, up.id, n - 1, up.part_count),
         {:ok, etag} <- upload_part(up, n, sealed) do
      # One atomic jsonb merge, so concurrent parts cannot lose each other.
      {count, _} =
        Repo.with_tenant(user.id, fn ->
          from(u in scoped(user, vault),
            where: u.id == ^up.id,
            update: [
              set: [
                parts:
                  fragment(
                    "? || jsonb_build_object(?::text, ?::text)",
                    u.parts,
                    ^Integer.to_string(n),
                    ^etag
                  ),
                updated_at: ^DateTime.utc_now(:second)
              ]
            ]
          )
          |> Repo.update_all([])
        end)
        |> unwrap()
        |> elem(1)

      if count == 1, do: {:ok, %{part: n}}, else: {:error, :not_found}
    end
  end

  @doc "Which parts the server holds, for a client resuming an upload."
  @spec status(map(), map(), Ecto.UUID.t()) ::
          {:ok, %{done: [pos_integer()], part_count: pos_integer(), part_size: pos_integer()}}
          | {:error, :not_found}
  def status(user, vault, upload_id) do
    with {:ok, up} <- fetch(user, vault, upload_id) do
      {:ok, %{done: done(up), part_count: up.part_count, part_size: up.part_size}}
    end
  end

  @doc """
  Assembles the parts and commits the live attachment. Refused while parts are
  missing (the session stays resumable) or when the file no longer fits the
  quota (the session and its blob are dropped).
  """
  @spec complete(map(), map(), Ecto.UUID.t()) ::
          {:ok, Attachment.t()}
          | {:error,
             :not_found
             | {:missing_parts, [pos_integer()]}
             | {:storage_cap_reached, integer(), integer()}
             | :rotation_in_progress
             | {:storage, term()}}
  def complete(user, vault, upload_id) do
    user = Crypto.fresh_user(user)

    with {:ok, up} <- fetch(user, vault, upload_id),
         do: complete_session(user, vault, up)
  end

  @doc false
  # `complete/3` past the fetch. Public so a test can replay a stale session
  # struct, which is what a second concurrent caller holds.
  @spec complete_session(map(), map(), Upload.t()) ::
          {:ok, Attachment.t()} | {:error, term()}
  def complete_session(user, vault, %Upload{} = up) do
    with [] <- Enum.to_list(1..up.part_count) -- done(up),
         # Early quota refusal: no point assembling and reading back the file.
         :ok <- quota(user, vault, up),
         {:ok, file_key} <- file_key(user, up, up.attachment_id),
         {:ok, up} <- assemble(user, vault, up),
         {:ok, hash} <- content_hash(user, up, file_key) do
      result = commit(user, vault, up, file_key, hash)

      _ =
        with {:error, {:storage_cap_reached, _, _}} <- result,
             do: drop(user, vault, up)

      result
    else
      missing when is_list(missing) -> {:error, {:missing_parts, missing}}
      {:error, {:storage_cap_reached, _, _}} = err -> refuse(user, vault, up.id, err)
      {:error, _} = err -> err
    end
  end

  @doc "Drops a session and whatever storage holds for it. Idempotent."
  @spec abort(map(), map(), Ecto.UUID.t()) :: :ok
  def abort(user, vault, upload_id) do
    case fetch(user, vault, upload_id) do
      {:ok, up} -> drop(user, vault, up)
      {:error, :not_found} -> :ok
    end
  end

  @doc """
  Drops an abandoned session (the expiry sweep's entry point). Same path as
  `abort/3`, so a concurrent `complete/3` and the sweep cannot both act.
  """
  @spec expire(Upload.t()) :: :ok
  def expire(%Upload{} = up), do: drop(%{id: up.user_id}, %{id: up.vault_id}, up)

  # -- Private --

  defp cast_request(attrs) do
    {%{}, @request_types}
    |> Ecto.Changeset.cast(attrs, Map.keys(@request_types))
    |> Ecto.Changeset.validate_required([:path, :size_bytes])
    |> Ecto.Changeset.validate_number(:size_bytes, greater_than: 0)
    |> Ecto.Changeset.apply_action(:insert)
  end

  defp fetch(user, vault, upload_id) do
    with {:ok, id} <- Ecto.UUID.cast(upload_id),
         {:ok, %Upload{} = up} <-
           Repo.with_tenant(user.id, fn ->
             Repo.one(from(u in scoped(user, vault), where: u.id == ^id))
           end)
           |> unwrap() do
      {:ok, up}
    else
      _ -> {:error, :not_found}
    end
  end

  defp check_part(%Upload{part_count: count}, n, _size)
       when not is_integer(n) or n < 1 or n > count,
       do: {:error, :bad_part_number}

  defp check_part(%Upload{} = up, n, size),
    do: if(size == part_bytes(up, n - 1), do: :ok, else: {:error, :bad_part_size})

  # Plaintext length of segment `index` (0-based).
  defp part_bytes(%Upload{part_count: count, part_size: ps, size_bytes: total}, index),
    do: if(index == count - 1, do: total - (count - 1) * ps, else: ps)

  defp done(%Upload{parts: parts}),
    do: parts |> Map.keys() |> Enum.map(&String.to_integer/1) |> Enum.sort()

  defp file_key(user, %Upload{} = up, bound_id) do
    with {:ok, dek} <- Crypto.get_dek(user),
         {:ok, key} <-
           SegmentedCipher.unwrap_key(up.wrapped_file_key, up.file_key_nonce, dek, bound_id) do
      {:ok, key}
    else
      _ -> {:error, :decrypt_failed}
    end
  end

  defp path_aad(upload_id), do: Crypto.aad_for_row(:attachment_uploads, :path, upload_id)

  defp quota(user, vault, %Upload{} = up) do
    existing = Attachments.fetch_existing(user, vault.id, up.path_hmac)
    Attachments.validate_storage_cap(user, existing, up.size_bytes)
  end

  # The content HMAC over the whole plaintext, read back one segment at a
  # time (parts arrive out of order and can repeat, so no running MAC at PUT
  # time). Opening each segment also proves storage holds exactly what was
  # sealed, in order, untruncated.
  defp content_hash(user, %Upload{} = up, file_key) do
    {:ok, content_key} = Crypto.dek_content_hash_key(user)
    sealed = up.part_size + SegmentedCipher.overhead()

    Enum.reduce_while(
      0..(up.part_count - 1),
      {:ok, :crypto.mac_init(:hmac, :sha256, content_key)},
      fn
        i, {:ok, mac} ->
          len = part_bytes(up, i) + SegmentedCipher.overhead()

          with {:ok, segment} <- Storage.adapter().get_range(up.storage_key, i * sealed, len),
               {:ok, plain} <-
                 SegmentedCipher.open_segment(segment, file_key, up.id, i, up.part_count) do
            {:cont, {:ok, :crypto.mac_update(mac, plain)}}
          else
            :error -> {:halt, {:error, {:storage, :segment_corrupt}}}
            {:error, reason} -> {:halt, {:error, {:storage, reason}}}
          end
      end
    )
    |> case do
      {:ok, mac} -> {:ok, mac |> :crypto.mac_final() |> Base.encode16(case: :lower)}
      err -> err
    end
  end

  # `up` was read when complete began, possibly minutes ago: a rotation that
  # finished since rewrapped the session row, not this struct. Refused on the
  # session's DEK version, here (before using the DEK) and again under the
  # locks; the client's retry reads the rewrapped session.
  defp commit(user, vault, %Upload{} = up, file_key, hash) do
    with :ok <- Attachments.rotation_gate(user, up.dek_version),
         {:ok, dek} <- Crypto.get_dek(user),
         {:ok, filter_key} <- Crypto.dek_filter_key(user),
         {:ok, path} <- decrypt_path(up, dek) do
      write_attachment(user, vault, up, path, {dek, filter_key}, file_key, hash)
    end
  end

  defp decrypt_path(%Upload{} = up, dek) do
    case Envelope.decrypt(up.path_ciphertext, up.path_nonce, dek, path_aad(up.id)) do
      {:ok, path} -> {:ok, path}
      :error -> {:error, :decrypt_failed}
    end
  end

  defp write_attachment(user, vault, up, path, {dek, filter_key}, file_key, hash) do
    basename_hmac = Crypto.hmac_field(filter_key, Links.basename_key(path))

    Attachments.commit_row(user, vault, path, up.path_hmac, up.size_bytes, up.dek_version, fn
      existing ->
        # Consumed first, in the same transaction as the row write: a duplicate
        # concurrent complete finds it gone and rolls back.
        with :ok <- delete_session(user, vault, up) do
          id = commit_id(user, vault, existing, up.attachment_id)

          # A different row won the path since start (a single-request upload,
          # or the claimed row was deleted): bind the file key to the winner's
          # id. A 32-byte rewrap, not a re-encrypt.
          {wrapped, key_nonce} =
            if id == up.attachment_id,
              do: {up.wrapped_file_key, up.file_key_nonce},
              else: SegmentedCipher.wrap_key(file_key, dek, id)

          {:ok, id,
           Map.merge(
             %{
               content_hash: hash,
               mime_type: up.mime_type,
               size_bytes: up.size_bytes,
               mtime: up.mtime,
               user_id: user.id,
               vault_id: vault.id,
               storage_key: up.storage_key,
               deleted_at: nil,
               encryption_version: 2,
               dek_version: Crypto.row_version_aad_bound(),
               content_nonce: nil,
               wrapped_file_key: wrapped,
               file_key_nonce: key_nonce,
               upload_id: up.id,
               segment_size: up.part_size,
               segment_count: up.part_count
             },
             Attachments.path_attrs(dek, id, path, {up.path_hmac, basename_hmac})
           )}
        end
    end)
  end

  # The live row's id when one holds the path; else the id claimed at start,
  # unless a since-deleted row still owns it (tombstones keep their id).
  defp commit_id(_user, _vault, %Attachment{id: id}, _claimed), do: id

  defp commit_id(user, vault, nil, claimed) do
    {:ok, taken?} =
      Repo.with_tenant(user.id, fn ->
        Repo.exists?(from(a in Attachments.scoped(user, vault), where: a.id == ^claimed))
      end)
      |> unwrap()

    if taken?, do: Ecto.UUID.generate(), else: claimed
  end

  defp refuse(user, vault, upload_id, err) do
    # Already consumed by another caller: nothing left to drop.
    _ = with {:ok, up} <- fetch(user, vault, upload_id), do: drop(user, vault, up)
    err
  end

  # Before assembly there is a multipart upload to abort; after it, an
  # object to delete. Deleting is harmless when nothing was assembled.
  # Storage is touched only by the caller that consumed the session: a stale
  # duplicate must not delete a blob a committed row now uses.
  defp drop(user, vault, %Upload{} = up) do
    # Storage cleanup is best-effort and logs its own failures; a session
    # another caller consumed is theirs to clean up.
    _ =
      with :ok <- delete_session(user, vault, up) do
        if is_nil(up.assembled_at) do
          _ = abort_storage(up.storage_key, up.s3_upload_id)
          delete_object(up.storage_key)
        else
          # Belt and braces: a live row never shares a consumed session's key.
          unless referenced?(user, vault, up.storage_key), do: delete_object(up.storage_key)
        end
      end

    :ok
  end

  defp referenced?(user, vault, storage_key) do
    {:ok, found?} =
      Repo.with_tenant(user.id, fn ->
        Repo.exists?(
          from(a in Attachments.scoped(user, vault), where: a.storage_key == ^storage_key)
        )
      end)
      |> unwrap()

    found?
  end

  # `{:error, :not_found}` when another caller already consumed the session,
  # so a duplicate complete rolls back instead of committing twice.
  defp delete_session(user, vault, %Upload{id: id}) do
    Repo.with_tenant(user.id, fn ->
      Repo.delete_all(from(u in scoped(user, vault), where: u.id == ^id))
    end)
    |> unwrap()
    |> case do
      {:ok, {1, _}} -> :ok
      {:ok, {0, _}} -> {:error, :not_found}
    end
  end

  # Assembles the parts once. Recorded so a complete retried after a later
  # failure (readback, commit) does not re-assemble a multipart upload that
  # no longer exists.
  defp assemble(_user, _vault, %Upload{assembled_at: %DateTime{}} = up), do: {:ok, up}

  defp assemble(user, vault, %Upload{} = up) do
    now = DateTime.utc_now(:second)

    with :ok <- complete_storage(up) do
      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          Repo.update_all(from(u in scoped(user, vault), where: u.id == ^up.id),
            set: [assembled_at: now, updated_at: now]
          )
        end)
        |> unwrap()

      {:ok, %{up | assembled_at: now}}
    end
  end

  defp start_multipart(storage_key) do
    case Storage.adapter().start_multipart(storage_key) do
      {:ok, id} -> {:ok, id}
      {:error, reason} -> storage_error("start", storage_key, reason)
    end
  end

  defp upload_part(%Upload{} = up, n, sealed) do
    case Storage.adapter().upload_part(up.storage_key, up.s3_upload_id, n, sealed) do
      {:ok, etag} -> {:ok, etag}
      {:error, reason} -> storage_error("part PUT", up.storage_key, reason)
    end
  end

  defp complete_storage(%Upload{} = up) do
    parts =
      up.parts
      |> Enum.map(fn {n, etag} -> %{part_number: String.to_integer(n), etag: etag} end)
      |> Enum.sort_by(& &1.part_number)

    case Storage.adapter().complete_multipart_upload(up.storage_key, up.s3_upload_id, parts) do
      :ok -> :ok
      {:error, reason} -> storage_error("complete", up.storage_key, reason)
    end
  end

  # Best-effort cleanup: a failure leaves an unreferenced blob or multipart
  # upload (storage cost, not data loss), so it is logged, not raised.
  defp abort_storage(storage_key, s3_upload_id) do
    case Storage.adapter().abort_multipart_upload(storage_key, s3_upload_id) do
      :ok -> :ok
      {:error, reason} -> storage_error("abort", storage_key, reason)
    end
  end

  defp delete_object(storage_key) do
    case Storage.adapter().delete(storage_key) do
      :ok -> :ok
      {:error, reason} -> storage_error("delete", storage_key, reason)
    end
  end

  defp storage_error(op, storage_key, reason) do
    reason_str = Metadata.safe_reason(reason)

    Logger.error(
      "attachment chunked upload storage #{op} failed: #{reason_str}",
      Metadata.with_category(:error, :sync, storage_key: storage_key, reason: reason_str)
    )

    {:error, {:storage, reason}}
  end

  defp unwrap({:ok, {:ok, result}}), do: {:ok, result}
  defp unwrap({:ok, {:error, _} = err}), do: err
  defp unwrap({:ok, result}), do: {:ok, result}
  defp unwrap({:error, _} = err), do: err
end
