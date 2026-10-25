defmodule Engram.Attachments do
  @moduledoc """
  Attachments context — CRUD for binary file attachments.
  All operations are tenant-scoped via Repo.with_tenant/2.

  Binary storage goes to the configured S3-compatible adapter
  (MinIO locally, Tigris in prod). Ciphertext only: `encryption_version`
  1 is one DEK-sealed blob (single-request uploads), 2 is segmented under a
  per-file key (`Engram.Attachments.SegmentedCipher`, chunked uploads).
  """

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.Attachments.BulkUpdate
  alias Engram.Attachments.SegmentedCipher
  alias Engram.Billing
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Crypto.RotationGate
  alias Engram.Links
  alias Engram.Logger.Metadata
  alias Engram.Notes.Enqueue
  alias Engram.Notes.PathSanitizer
  alias Engram.Repo
  alias Engram.Storage
  alias Engram.Storage.MimeWhitelist
  alias Engram.Sync.Broadcast
  alias Engram.Workers.ReconcileAttachmentBlobs

  @doc """
  Composable tenant-scope query: `Attachment` rows owned by `user` in `vault`
  (struct or bare vault id). This predicate IS the multi-tenant isolation
  boundary — attachment queries must compose from `scoped/2` /
  `scoped_live/2`; `tenant_scope_lint_test.exs` flags hand-inlined
  `user_id == ^` predicates so a dropped clause can't slip in.
  """
  @spec scoped(map(), map() | term()) :: Ecto.Query.t()
  def scoped(user, %{id: vault_id}), do: scoped(user, vault_id)

  def scoped(user, vault_id) do
    from(a in Attachment, where: a.user_id == ^user.id and a.vault_id == ^vault_id)
  end

  @doc "`scoped/2` plus `is_nil(deleted_at)` — live (non-tombstoned) rows only."
  @spec scoped_live(map(), map() | term()) :: Ecto.Query.t()
  def scoped_live(user, vault) do
    from(a in scoped(user, vault), where: is_nil(a.deleted_at))
  end

  @doc """
  Upserts an attachment. Takes raw bytes under the atom key `:content`, or
  base64 under `content_base64`. Detects MIME type, computes hash.
  Returns {:ok, attachment} or {:error, reason}.
  """
  def upsert_attachment(user, vault, attrs) do
    path = (attrs["path"] || attrs[:path]) |> PathSanitizer.sanitize()
    mtime = attrs["mtime"] || attrs[:mtime]
    explicit_mime = attrs["mime_type"] || attrs[:mime_type]

    with {:ok, plaintext} <- attachment_bytes(attrs),
         # Security boundary: enforced HERE, not (only) in the controller —
         # MCP tools, Oban jobs, and console callers must hit the same gate.
         :ok <- MimeWhitelist.check(explicit_mime || MimeWhitelist.detect_mime(path), path),
         :ok <- validate_size(byte_size(plaintext), user),
         {:ok, user} <- Crypto.ensure_user_dek(user),
         # Before any key is derived: commit_row/7 refuses if a rotation
         # moved the DEK since (`RotationGate.check/2`).
         dek_version = RotationGate.dek_version(user.id),
         {:ok, filter_key} <- Crypto.dek_filter_key(user),
         path_hmac = Crypto.hmac_field(filter_key, path),
         # Pre-lock window: probable-id read, cap check, encrypt, and the S3
         # PUT all run WITHOUT holding a pool transaction or the advisory
         # lock — a slow multi-MB upload must not pin a DB connection
         # (POOL_SIZE defaults to 10; a handful of concurrent uploads used to
         # starve the whole API). The locked transaction below re-checks
         # `existing` and repairs the rare race.
         existing0 = fetch_existing(user, vault.id, path_hmac),
         # Re-offering bytes the server already holds is a no-op. Returning the
         # live row here skips the encrypt, the S3 PUT, the locked row write
         # AND the "upsert" broadcast every peer would otherwise chase. See
         # `identical_or_changed/5`.
         :changed <-
           identical_or_changed(user, existing0, plaintext, path, explicit_mime) do
      basename_hmac = Crypto.hmac_field(filter_key, Links.basename_key(path))

      att_id0 =
        case existing0 do
          nil -> Ecto.UUID.generate()
          %Attachment{id: id} -> id
        end

      # Every write stores its ciphertext under a fresh key, never over the
      # live row's blob: this PUT runs before the lock, and a refusal under
      # the lock must leave the live row and its bytes as they were. On
      # commit the row moves to the new key and commit_row/6 releases the
      # old blob; on any refusal the new blob is deleted.
      key = Storage.object_key(user.id, vault.id, Ecto.UUID.generate())

      prepare = fn id ->
        prepare_upload(
          user,
          vault,
          {id, key},
          path,
          {path_hmac, basename_hmac},
          plaintext,
          mtime,
          explicit_mime
        )
      end

      with :ok <- validate_storage_cap(user, existing0, byte_size(plaintext)),
           {:ok, attrs0, ciphertext} <- prepare.(att_id0),
           :ok <- store_external(key, ciphertext, attrs0.mime_type) do
        # T3-audit H1 — the content AAD binds the row id, so if the locked
        # re-read finds a different row holding the path, re-encrypt for its
        # id and re-PUT, to the same fresh key (rare race path only).
        reprepare = fn id ->
          with {:ok, attrs1, ciphertext1} <- prepare.(id),
               :ok <- store_external(key, ciphertext1, attrs1.mime_type),
               do: {:ok, id, attrs1}
        end

        deleting_blob_on_raise(user, vault, key, fn ->
          commit_row(user, vault, path, path_hmac, byte_size(plaintext), dek_version, fn
            %Attachment{id: id} when id != att_id0 ->
              reprepare.(id)

            %Attachment{} ->
              {:ok, att_id0, attrs0}

            # The row read before the lock was deleted (or moved) since: its
            # id stays taken by the tombstone, so a fresh row needs a fresh
            # id (as `Uploads` does for a claimed id).
            nil ->
              if existing0,
                do: reprepare.(Ecto.UUID.generate()),
                else: {:ok, att_id0, attrs0}
          end)
        end)
        |> tap(fn
          {:ok, _} -> :ok
          {:error, _} -> delete_external(key)
        end)
      end
    end
  end

  # A raise in the locked write (a storage client error on the re-PUT, a
  # constraint) must not orphan the fresh blob. Deleted only while no row
  # points at it, so a raise after the commit cannot reach a live blob. The
  # raise is often the rotation gate refusing the write; the check is a read
  # and runs ungated, or it would raise the same way and skip the delete.
  defp deleting_blob_on_raise(user, vault, key, fun) do
    fun.()
  rescue
    e ->
      unless RotationGate.ungated(fn -> blob_referenced?(user, vault, key) end),
        do: delete_external(key)

      reraise e, __STACKTRACE__
  end

  defp blob_referenced?(user, vault, key) do
    Repo.with_tenant!(user.id, fn ->
      Repo.exists?(from(a in scoped(user, vault), where: a.storage_key == ^key))
    end)
  end

  @doc false
  # The locked row write shared by single-request uploads (above) and chunked
  # ones (`Engram.Attachments.Uploads.complete/3`). Takes the per-path
  # advisory lock, re-reads the live row at `path_hmac`, then takes the
  # per-user quota lock and re-checks the storage cap for `size` against live
  # usage (two uploads to different paths would otherwise both pass). Then
  # hands the live row (or nil) to `build`, which returns
  # `{:ok, insert_id, attrs}`; `insert_id` is used only when no live row holds
  # the path. Lock order is always path then user. Both locks auto-release on
  # commit/rollback, and an `{:error, reason}` from `build` rolls back.
  #
  # After commit: releases the replaced row's blob when the new write moved
  # the row to a different storage key, then broadcasts the upsert.
  @spec commit_row(
          map(),
          map(),
          String.t(),
          binary(),
          non_neg_integer(),
          integer() | nil,
          (Attachment.t() | nil ->
             {:ok, Ecto.UUID.t(), map()}
             | {:error, term()})
        ) ::
          {:ok, Attachment.t()} | {:error, term()}
  def commit_row(user, vault, path, path_hmac, size, dek_version, build) do
    Repo.transaction(fn ->
      :ok = acquire_path_lock(user.id, path_hmac)
      existing = fetch_existing(user, vault.id, path_hmac)
      :ok = Repo.advisory_lock!(quota_lock_id(user.id))

      # Under the locks and before anything is written: a row committed after
      # a DEK rotation's sweep went by would stay under the retiring key.
      with :ok <- rotation_gate(user, dek_version),
           :ok <- validate_storage_cap(user, existing, size),
           {:ok, insert_id, attrs} <- build.(existing),
           {:ok, att} <- write_row(user, existing, insert_id, attrs) do
        # Phase B.3: path is virtual — splice the plaintext we already have
        # onto the returned struct so callers can read att.path without a
        # second decrypt round-trip.
        {%{att | path: path}, existing}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {att, existing}} ->
        :ok = release_replaced_blob(user, vault, path_hmac, existing, att)

        # Real-time notification (Engram#942) — create/upload previously had
        # NO live signal at all (only delete and move broadcast), so peers
        # only ever saw a new/changed attachment via the next manual pull.
        # The plugin's WebSocket handler already fetches + materializes any
        # attachment "upsert" event, so no plugin change is needed.
        broadcast_attachment(user.id, vault.id, "upsert", path, att)
        {:ok, att}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  `{:error, :rotation_in_progress}` while a DEK rotation holds the user (read
  fresh, never from a cached struct), or, given `dek_version`, once one has
  completed since the caller read that version. Inside a transaction it also holds the
  user row against a rotation starting before the caller commits
  (`RotationGate.check/2`). Fails closed on a missing user.
  """
  @spec rotation_gate(map(), integer() | nil) :: :ok | {:error, :rotation_in_progress}
  def rotation_gate(user, dek_version \\ nil) do
    opts = [share_lock: Repo.in_transaction?()]
    opts = if dek_version, do: [{:dek_version, dek_version} | opts], else: opts

    case RotationGate.check(user.id, opts) do
      :ok -> :ok
      {:error, _} -> {:error, :rotation_in_progress}
    end
  end

  @doc false
  # Per-user lock serializing the storage-cap check with the row write.
  # Hashed by `Repo.advisory_lock!/1`, a different derivation from
  # acquire_path_lock/2's, so the two keyspaces do not meet by construction.
  def quota_lock_id(user_id), do: "attachment_quota:" <> user_id

  # Every write moves the row to a fresh storage key (single-request and
  # chunked alike), which leaves the old blob unreferenced. Deleted under the
  # path lock, and only if the live row has not since been pointed back at
  # it.
  #
  # ponytail: path lock only. A concurrent move of the row to another path
  # plus a single-request upload there is not serialized against this
  # delete; lock on the row id if that ever shows up.
  defp release_replaced_blob(
         user,
         vault,
         path_hmac,
         %Attachment{storage_key: old},
         %Attachment{storage_key: new}
       )
       when is_binary(old) and old != new do
    {:ok, :ok} =
      Repo.transaction(fn ->
        :ok = acquire_path_lock(user.id, path_hmac)

        # After commit (#2159): built in, so a caller that ever nests the
        # upload in a longer transaction cannot delete a blob its rollback
        # would point the row back at.
        case fetch_existing(user, vault.id, path_hmac) do
          %Attachment{storage_key: ^old} -> :ok
          _ -> Repo.after_commit(fn -> delete_external(old) end)
        end
      end)

    :ok
  end

  defp release_replaced_blob(_user, _vault, _path_hmac, _existing, _att), do: :ok

  # `{:ok, att}` when the stored bytes are already the offered bytes (the `with`
  # above short-circuits and returns it); `:changed` otherwise.
  #
  # Why this exists: on 2026-08-21 a single looping Obsidian client re-uploaded
  # the same 667 attachments for 90 minutes and held prod at ~30% CPU on a
  # 0.5-vCPU task. Every request was individually legal and no limit came close
  # — the loop ran at ~1 req/s against a 30 rps cap, and a bytes/minute cap
  # would not have helped either (it moved ~45 MB/min, well UNDER a legitimate
  # first sync's ~240 MB/min). Rate is not what separates a loop from a bulk
  # import; redundancy is.
  #
  # Gated on the effective MIME as well as the bytes. Content alone is NOT
  # enough: re-uploading identical bytes with a corrected `mime_type` is the
  # documented way to fix a mis-detected type, and short-circuiting on content
  # alone silently discarded that correction while returning 200 with the OLD
  # type. A MIME change falls through to the full write — wasteful for a
  # metadata-only edit, but rare, and obviously correct.
  #
  # `mtime` deliberately does NOT gate. It is client-reported metadata that no
  # read path consults: the plugin's `applyAttachmentChange` decides by
  # comparing BYTES, not mtime, so a preserved-old mtime cannot strand or loop
  # a client. Gating on it would spend a full re-encrypt + PUT on a field
  # nothing reads.
  #
  # Trusts the row only once the blob is confirmed present (#2159): if the
  # object is gone behind a live row, the identical upload falls through to
  # the full write, which seals the bytes under a fresh key exactly as any
  # upload does and repoints the row. On a backend with no versions to
  # restore from, the client's matching local copy is the only source left.
  # Costs one HEAD per identical re-upload.
  defp identical_or_changed(_user, nil, _plaintext, _path, _explicit_mime), do: :changed

  defp identical_or_changed(
         user,
         %Attachment{content_hash: stored} = att,
         plaintext,
         path,
         explicit_mime
       )
       when is_binary(stored) do
    effective_mime = explicit_mime || MimeWhitelist.detect_mime(path)

    with true <- att.mime_type == effective_mime,
         # Not a secret comparison — both sides are HMACs over content the
         # caller just supplied, so there is no oracle to time. Plain `==`.
         {:ok, content_key} <- Crypto.dek_content_hash_key(user),
         true <- stored == Crypto.hmac_content_hash(content_key, plaintext),
         true <- blob_present?(att) do
      # `path` is virtual (Phase B.3); splice it on so this return is
      # shape-identical to the write path's.
      {:ok, %{att | path: path}}
    else
      _ -> :changed
    end
  end

  defp identical_or_changed(_user, _existing, _plaintext, _path, _explicit_mime), do: :changed

  defp blob_present?(%Attachment{storage_key: key} = att) when is_binary(key) do
    Storage.adapter().exists?(key) or blob_healing(att)
  end

  defp blob_present?(att), do: blob_healing(att)

  # false: the identical upload proceeds as a full write and restores it.
  defp blob_healing(att) do
    require Logger

    Logger.info(
      "attachment blob healed from client",
      Metadata.with_category(:info, :sync, attachment_id: att.id)
    )

    false
  end

  @doc false
  def fetch_existing(user, vault_id, path_hmac) do
    Repo.with_tenant(user.id, fn ->
      Repo.one(from(a in scoped_live(user, vault_id), where: a.path_hmac == ^path_hmac))
    end)
    |> unwrap_tenant()
    |> case do
      {:ok, att} -> att
      {:error, _} -> nil
    end
  end

  defp write_row(user, existing, fallback_id, changeset_attrs) do
    Repo.with_tenant(user.id, fn ->
      # Sync backbone: stamp a monotonic seq inside the same tenant txn so the
      # bump and the row write commit atomically. Applies to insert + update.
      # version mirrors notes.version for resurrection parity: an update sets
      # existing.version + 1; an insert leaves the schema default (1) untouched.
      changeset_attrs =
        changeset_attrs
        |> Map.put(:seq, Engram.Vaults.next_seq!(changeset_attrs.vault_id))
        |> then(fn attrs ->
          case existing do
            %Attachment{version: v} -> Map.put(attrs, :version, v + 1)
            _ -> attrs
          end
        end)

      case existing do
        nil ->
          :ok = evict_counts(user.id)

          %Attachment{id: fallback_id}
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

  # T3-audit H1 — txn-scoped advisory lock keyed on (user_id, path_hmac).
  # Postgres `pg_advisory_xact_lock(bigint)` takes a single 64-bit key; we
  # derive it from `:erlang.phash2/2` over the (user_id, path_hmac) tuple.
  # Collisions are tolerable: a hash collision causes an unrelated upload
  # to wait, which is at most a latency cost, not a correctness issue.
  defp acquire_path_lock(user_id, path_hmac) do
    key = :erlang.phash2({user_id, path_hmac}, 2_147_483_647)
    _ = Repo.query!("SELECT pg_advisory_xact_lock($1)", [key])
    :ok
  end

  @doc """
  Gets an attachment by path. Returns nil for soft-deleted.

  Format v1: `content` is the plaintext, fetched and decrypted here.
  Format v2: `content` is `{:segments, stream}`, the whole file as a lazy
  `segment_stream/4`; nothing is fetched until it is consumed.
  """
  def get_attachment(user, vault, path) do
    path = PathSanitizer.sanitize(path)
    user = fresh_user(user)

    result =
      with {:ok, filter_key} <- Crypto.dek_filter_key(user) do
        path_hmac = Crypto.hmac_field(filter_key, path)

        Repo.with_tenant(user.id, fn ->
          Repo.one(from(a in scoped_live(user, vault), where: a.path_hmac == ^path_hmac))
        end)
        |> unwrap_tenant()
      end

    case result do
      {:error, :no_dek} ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      # A row with no storage_key is a broken row, not a legacy shape to be
      # recovered. This used to fall back to `Storage.key/3`, which rebuilt
      # "user/vault/<cleartext path>" at READ time — so a path ended up in the
      # S3 URL, and from there in ExAws's own log line, S3 access logs and
      # bucket listings, none of which any call-site control can reach. Blobs
      # are keyed by a UUID (`Storage.object_key/3`) and read only via the
      # row's storage_key; nothing reconstructs a key from a path any more, and the builder that
      # could is deleted.
      {:ok, %Attachment{storage_key: nil} = att} ->
        require Logger

        Logger.error(
          "Attachment row has no storage_key",
          Metadata.with_category(:error, :sync, attachment_id: att.id)
        )

        {:error, {:storage, :blob_missing}}

      {:ok, %Attachment{encryption_version: 2} = att} ->
        {:ok, att} = Crypto.maybe_decrypt_attachment_fields(att, user)

        with {:ok, stream} <- segment_stream(user, att, 0, att.size_bytes - 1),
             do: {:ok, %{att | content: {:segments, stream}}}

      {:ok, %Attachment{} = att} ->
        {:ok, att} = Crypto.maybe_decrypt_attachment_fields(att, user)
        key = att.storage_key

        case Storage.adapter().get(key) do
          {:ok, ciphertext} ->
            decrypt(att, ciphertext, user)

          {:error, :not_found} ->
            # Live row with missing blob = storage corruption, not a normal 404
            require Logger

            Logger.error(
              "Attachment blob missing for live row",
              Metadata.with_category(:error, :sync,
                attachment_id: att.id,
                storage_key: key
              )
            )

            :ok = reconcile_blobs(att)
            {:error, {:storage, :blob_missing}}

          {:error, reason} ->
            require Logger
            # safe_reason/1, not inspect/1. `storage_key` above is redacted by key, but
            # this value is not — `:reason` is absent from RedactFilter's set, and it
            # goes into the message BODY as well, which nothing filters. For legacy
            # `key` comes from the storage_key column, so an
            # ExAws error that echoes the key would print the path.
            reason_str = Metadata.safe_reason(reason)

            Logger.error(
              "attachment storage GET failed: #{reason_str}",
              Metadata.with_category(:error, :sync,
                attachment_id: att.id,
                storage_key: key,
                reason: reason_str
              )
            )

            {:error, {:storage, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Plaintext bytes `first..last` (inclusive) of a format-v2 attachment: a lazy
  stream of `{:ok, bytes} | {:error, reason}`, one item per segment touched,
  trimmed to the range. Each segment is fetched with a ranged GET and opened
  only when the stream reaches it. Consumers stop at the first error, which
  is already logged here.

  The segment count comes from the row, never from the object's size: the
  final-segment flag in the AAD only catches a truncated object if the
  count is authoritative.
  """
  @spec segment_stream(map(), Attachment.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, Enumerable.t()} | {:error, :decrypt_failed}
  def segment_stream(
        user,
        %Attachment{encryption_version: 2, size_bytes: size} = att,
        first,
        last
      )
      when is_integer(first) and is_integer(last) and 0 <= first and first <= last and
             last < size do
    with {:ok, dek} <- Crypto.get_dek(fresh_user(user)),
         {:ok, key} <-
           SegmentedCipher.unwrap_key(att.wrapped_file_key, att.file_key_nonce, dek, att.id) do
      seg = att.segment_size

      {:ok,
       Stream.map(div(first, seg)..div(last, seg)//1, fn i ->
         with {:ok, plain} <- read_segment(att, key, i) do
           lo = max(first - i * seg, 0)
           hi = min(last - i * seg, byte_size(plain) - 1)
           {:ok, binary_part(plain, lo, hi - lo + 1)}
         end
       end)}
    else
      _ -> {:error, :decrypt_failed}
    end
  end

  defp read_segment(%Attachment{segment_size: seg, segment_count: count} = att, key, i) do
    overhead = SegmentedCipher.overhead()
    plain_len = if i == count - 1, do: att.size_bytes - (count - 1) * seg, else: seg

    offset = i * (seg + overhead)

    result =
      case Storage.adapter().get_range(att.storage_key, offset, plain_len + overhead) do
        {:ok, sealed} ->
          with :error <- SegmentedCipher.open_segment(sealed, key, att.upload_id, i, count),
               do: {:error, :segment_corrupt}

        {:error, :not_found} ->
          :ok = reconcile_blobs(att)
          {:error, {:storage, :not_found}}

        {:error, reason} ->
          {:error, {:storage, reason}}
      end

    case result do
      {:ok, plain} ->
        {:ok, plain}

      {:error, reason} = err ->
        require Logger
        # No path and no bytes: the id and segment index locate the damage.
        reason_str = Metadata.safe_reason(reason)

        Logger.error(
          "attachment segment unreadable: #{reason_str}",
          Metadata.with_category(:error, :sync,
            attachment_id: att.id,
            segment: i,
            reason: reason_str
          )
        )

        err
    end
  end

  @doc """
  Soft-deletes an attachment. Idempotent — returns :ok even if already deleted or nonexistent;
  `{:error, reason}` only when the delete could not run (DEK unwrap or tenant transaction failed).

  The blob is NOT deleted here (#2159): the tombstone keeps its `storage_key`
  and `Engram.Workers.AttachmentBlobGC` reaps it after a grace window, so a
  delete that rolls back (or is undone) can never leave a live row without
  bytes.

  `op_id:` stamps the tombstone with that undo id (#609); see
  `Engram.Folders.restore_op/3`.
  """
  @spec delete_attachment(Engram.Accounts.User.t(), map(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def delete_attachment(user, vault, path, opts \\ []) do
    case delete_attachment_reporting(user, vault, path, opts) do
      {:error, _} = err -> err
      _ -> :ok
    end
  end

  @doc """
  `delete_attachment/4`, reporting whether a live attachment was there:
  `:deleted` or `:absent`.
  """
  @spec delete_attachment_reporting(Engram.Accounts.User.t(), map(), String.t(), keyword()) ::
          :deleted | :absent | {:error, term()}
  def delete_attachment_reporting(user, vault, path, opts \\ []) do
    do_delete_attachment(fresh_user(user), vault, path, opts)
  end

  # Soft-deletes one attachment: `:deleted` when a live row transitioned,
  # `:absent` for an absent/already-deleted path, `{:error, reason}` when the
  # delete could not run.
  # Single-delete path only — `batch_delete/3` has its own one-transaction
  # implementation with the same broadcast payload + blob-cleanup contract.
  # opts[:origin_device_id] is stamped into the delete broadcast (#970) so the
  # originating device can drop its own fanout echo.
  defp do_delete_attachment(user, vault, path, opts) do
    path = PathSanitizer.sanitize(path)
    now = DateTime.utc_now(:second)

    case Crypto.dek_filter_key(user) do
      {:ok, filter_key} ->
        path_hmac = Crypto.hmac_field(filter_key, path)

        result =
          Repo.with_tenant(user.id, fn ->
            live = from(a in scoped_live(user, vault), where: a.path_hmac == ^path_hmac)

            # Unlocked pre-check so an absent path neither bumps the vault seq
            # nor waits on the vault row lock. The lock order (vault, then
            # attachment) stays the same as upsert's; a delete that races in
            # between just makes update_all below match 0 rows.
            if Repo.exists?(live) do
              seq = Engram.Vaults.next_seq!(vault.id)

              {count, _} =
                Repo.update_all(live,
                  set: [
                    deleted_at: now,
                    updated_at: now,
                    seq: seq,
                    delete_op_id: Keyword.get(opts, :op_id)
                  ]
                )

              if count > 0, do: :ok = evict_counts(user.id)
              count
            else
              0
            end
          end)
          |> unwrap_tenant()

        # The blob stays for AttachmentBlobGC (#2159).
        status =
          case result do
            {:ok, count} when count > 0 ->
              :deleted

            {:ok, 0} ->
              :absent

            {:error, reason} ->
              require Logger

              Logger.warning(
                "delete_attachment: tenant lookup failed",
                Metadata.with_category(:warning, :sync, reason: Metadata.safe_reason(reason))
              )

              {:error, reason}
          end

        # Real-time notification — only when a live row actually transitioned to
        # deleted (idempotent no-op deletes of an absent/already-deleted path
        # don't emit a spurious delete). path/vault are known; mime/size/mtime
        # are gone post-delete, so only the discriminators the plugin needs to
        # trash are sent.
        _ =
          if status == :deleted do
            payload = %{
              "event_type" => "delete",
              "kind" => "attachment",
              "path" => path,
              "vault_id" => vault.id
            }

            # Origin attribution (#970) — same contract as the notes delete
            # broadcast: lets the originating device drop its own fanout echo.
            payload =
              case Keyword.get(opts, :origin_device_id) do
                device_id when is_binary(device_id) -> Map.put(payload, "device_id", device_id)
                _ -> payload
              end

            Broadcast.emit("sync:#{user.id}:#{vault.id}", "note_changed", payload)
          end

        status

      {:error, :no_dek} ->
        # No DEK = no attachments to delete; mirror get_attachment's defensive empty.
        :absent

      # DEK unwrap failed (KMS outage, unrecognised blob). Nothing was deleted.
      {:error, _} = err ->
        err
    end
  end

  defp delete_external(storage_key) when is_binary(storage_key) do
    case Storage.adapter().delete(storage_key) do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning(
          "Failed to delete blob (row already soft-deleted)",
          Metadata.with_category(:warning, :sync,
            storage_key: storage_key,
            reason: Metadata.safe_reason(reason)
          )
        )

        :ok
    end
  end

  @doc """
  Moves/renames an attachment by path. One transaction under the per-vault seq:
  repoint the live row (id stable, path re-encrypted under its unchanged
  id-AAD, storage_key + blob untouched) and insert a soft-deleted tombstone at
  the old path so poll/cursor clients converge (trash old, write new). Mirrors
  `Engram.Notes.rename_folder/4`'s tombstone discipline (#614).
  """
  @spec move_attachment(map(), map(), String.t(), String.t()) ::
          {:ok, Attachment.t()}
          | {:error, :conflict | :not_found | :feature_not_available | term()}
  def move_attachment(user, vault, old_path, new_path) do
    # `attachments_enabled` is gated HERE, not in the caller. REST
    # (`AttachmentsController.rename/2`) and MCP (the `move_attachment` tool)
    # both land on this function; while the check lived in the controller, only
    # REST was refused. Same class as the MCP search-cap bypass — see
    # `docs/context/mcp-bypasses-path-shaped-plugs.md`. It runs ahead of the
    # lookup so a revoked plan cannot be probed for which paths exist.
    #
    # The gate is on THIS function and not on `do_move_attachment/4`, which is
    # also the per-item step of `rename_folder/4`. That cascade is server
    # -internal: `Folders.rename/4` runs it after `Notes.rename_folder/4` on
    # every folder rename. Gating the shared mover refused the attachment leg
    # and rolled the whole folder rename back, so a revoked attachments grant
    # read as "you cannot rename a folder". Gate the user-initiated entry
    # points (`move_attachment/4`, `batch_move/4`); leave the cascade alone.
    with :ok <- Billing.check_feature(user, :attachments_enabled),
         :ok <- check_move_target(new_path) do
      do_move_attachment(user, vault, old_path, new_path)
    end
  end

  # The executable blocklist on user moves: a rename is a write of the new
  # path, so notes.txt -> evil.exe must meet the same gate as an upload.
  # Folder renames (`rename_folder/4`) keep every basename and so cannot
  # change an extension; they stay ungated, like the plan gate above.
  defp check_move_target(new_path),
    do: MimeWhitelist.check(nil, PathSanitizer.sanitize(new_path))

  defp do_move_attachment(user, vault, old_path, new_path) do
    old_path = PathSanitizer.sanitize(old_path)
    new_path = PathSanitizer.sanitize(new_path)
    user = fresh_user(user)
    now = DateTime.utc_now(:second)

    with {:ok, user} <- Crypto.ensure_user_dek(user),
         {:ok, dek} <- Crypto.get_dek(user),
         {:ok, filter_key} <- Crypto.dek_filter_key(user) do
      old_hmac = Crypto.hmac_field(filter_key, old_path)
      new_hmac = Crypto.hmac_field(filter_key, new_path)
      old_basename_hmac = Crypto.hmac_field(filter_key, Links.basename_key(old_path))
      new_basename_hmac = Crypto.hmac_field(filter_key, Links.basename_key(new_path))

      # Errors are returned, never `Repo.rollback`: nothing is written before
      # a refusal, and a rollback here would poison an enclosing transaction
      # (an MCP tool call, the folder-rename cascade) instead of reporting.
      Repo.with_tenant(user.id, fn ->
        live = Repo.one(live_by_hmac_query(user, vault, old_hmac))

        cond do
          is_nil(live) ->
            {:error, :not_found}

          old_path == new_path ->
            Crypto.maybe_decrypt_attachment_fields(live, user)

          Repo.one(live_by_hmac_query(user, vault, new_hmac)) ->
            {:error, :conflict}

          true ->
            # Both writes share ONE seq inside ONE transaction (#614): a cursor
            # pull must never see the repoint at seq S, advance past S, and miss
            # the tombstone also at S.
            seq = Engram.Vaults.next_seq!(vault.id)

            # Repoint the live row: re-encrypt path under the SAME id-AAD (id is
            # unchanged, so the AAD bind is unchanged), recompute path_hmac, bump
            # updated_at + seq. storage_key + blob untouched.
            path_aad = Crypto.aad_for_row(:attachments, :path, live.id)
            {path_ct, path_n} = Envelope.encrypt(new_path, dek, path_aad)

            {1, _} =
              from(a in Attachment, where: a.id == ^live.id)
              |> Repo.update_all(
                set:
                  [
                    path_ciphertext: path_ct,
                    path_nonce: path_n,
                    path_hmac: new_hmac,
                    basename_hmac: new_basename_hmac,
                    updated_at: now,
                    seq: seq
                  ] ++ Links.path_keys(filter_key, new_path, path_n)
              )

            # Insert the old-path tombstone (fresh uuid, path encrypted under
            # ITS OWN id-AAD). Sole purpose: surface {old_path, deleted: true}
            # in the change feed so clients trash the old path.
            :ok = evict_counts(user.id)

            Repo.insert!(
              tombstone_changeset(
                user,
                vault,
                dek,
                old_path,
                {old_hmac, old_basename_hmac},
                live,
                seq,
                now
              )
            )

            {:ok,
             %{
               live
               | path: new_path,
                 path_ciphertext: path_ct,
                 path_nonce: path_n,
                 path_hmac: new_hmac,
                 basename_hmac: new_basename_hmac,
                 updated_at: now,
                 seq: seq
             }}
        end
      end)
      |> unwrap_tenant()
      |> case do
        {:ok, %Attachment{} = att} ->
          _ =
            if old_path != new_path do
              broadcast_attachment(user.id, vault.id, "delete", old_path, att)
              broadcast_attachment(user.id, vault.id, "upsert", new_path, att)

              # #648/#1231 — rewrite referring notes' ![[...]]/[[...]] targets.
              _ =
                Enqueue.enqueue(
                  Engram.Workers.RewriteNoteLinks.new_for(
                    user.id,
                    vault.id,
                    :attachment,
                    att.id,
                    Base.encode64(old_hmac),
                    Base.encode64(old_basename_hmac)
                  ),
                  "rewrite_note_links"
                )
            end

          {:ok, att}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp live_by_hmac_query(user, vault, hmac) do
    from(a in scoped_live(user, vault), where: a.path_hmac == ^hmac)
  end

  # Soft-deleted full-row insert at the vacated path. storage_key=nil (no blob),
  # content_hash and the content-format columns carried from the live row (the
  # changeset requires the live row's format to be complete; the values are
  # irrelevant, the row is deleted and never decrypted). Path encrypted under
  # the tombstone's OWN id-AAD so reads of the (never-served) row stay
  # AAD-consistent.
  defp tombstone_changeset(
         user,
         vault,
         dek,
         old_path,
         {old_hmac, old_basename_hmac},
         live,
         seq,
         now
       ) do
    tomb_id = Ecto.UUID.generate()
    path_aad = Crypto.aad_for_row(:attachments, :path, tomb_id)
    {path_ct, path_n} = Envelope.encrypt(old_path, dek, path_aad)

    Attachment.changeset(
      %Attachment{id: tomb_id},
      %{
        path_ciphertext: path_ct,
        path_nonce: path_n,
        path_hmac: old_hmac,
        basename_hmac: old_basename_hmac,
        content_hash: live.content_hash,
        mime_type: live.mime_type,
        size_bytes: live.size_bytes,
        mtime: live.mtime,
        user_id: user.id,
        vault_id: vault.id,
        storage_key: nil,
        deleted_at: now,
        seq: seq,
        version: 1,
        dek_version: Crypto.row_version_aad_bound()
      }
      |> Map.merge(content_format(live))
    )
  end

  # The columns that say how a row's content is sealed (v1 or v2), for a
  # row copied from `att`.
  defp content_format(%Attachment{encryption_version: 2} = att),
    do:
      Map.take(att, [
        :encryption_version,
        :wrapped_file_key,
        :file_key_nonce,
        :upload_id,
        :segment_size,
        :segment_count
      ])

  defp content_format(%Attachment{} = att),
    do: %{encryption_version: 1, content_nonce: att.content_nonce}

  @doc """
  Moves each attachment into `target_folder` (\"\" = root). All-or-nothing: any
  conflict/not_found rolls back every prior move's DB write.

  Caveat: each `move_attachment` broadcasts its `note_changed` events as its own
  inner transaction commits, BEFORE the outer rollback can fire — so a later
  failure can't retract earlier items' broadcasts. Clients self-heal on the next
  pull. Same trade-off as `Notes.rename_folder`; not worth deferring broadcasts.
  """
  @spec batch_move(map(), map(), [String.t()], String.t()) ::
          {:ok, %{moved: non_neg_integer()}} | {:error, {atom(), String.t()} | term()}
  def batch_move(_user, _vault, [], _target_folder), do: {:ok, %{moved: 0}}

  def batch_move(user, vault, paths, target_folder)
      when is_list(paths) and is_binary(target_folder) do
    # Each new path is sanitized again in do_move_attachment/4; this is for the
    # 422, so `..` is refused instead of silently landing in the vault root.
    case PathSanitizer.sanitize_target(target_folder) do
      {:ok, target_folder} -> do_batch_move(user, vault, paths, target_folder)
      {:error, _} = err -> err
    end
  end

  defp do_batch_move(user, vault, paths, target_folder) do
    pairs =
      Enum.map(paths, fn old_path ->
        base = Path.basename(old_path)
        new_path = if target_folder == "", do: base, else: Path.join(target_folder, base)
        {old_path, new_path}
      end)

    # User-initiated, so it carries its own gate — `move_pairs/4` runs the
    # UNGATED mover (see `move_attachment/4`) because `rename_folder/4` shares it.
    with :ok <- Billing.check_feature(user, :attachments_enabled),
         :ok <- Enum.find_value(pairs, :ok, &blocked_target/1) do
      # This surface tags conflict/not_found with the offending path so the REST
      # controller can name it in the 409/404 body (`{:conflict, path}`).
      case move_pairs(user, vault, pairs, &tag_move_error/2) do
        {:ok, count} -> {:ok, %{moved: count}}
        {:error, _} = err -> err
      end
    end
  end

  # Shared mover for every "relocate these [{old, new}] pairs atomically"
  # caller (`batch_move/4` + the folder-rename cascade). Set-based (#2159):
  # it was one `do_move_attachment/4` per pair, ~10 statements each, inside
  # one transaction, and a 7,440-attachment folder rename hit the 15 s
  # checkout kill. Now: one read of the sources, one of the targets, one seq
  # block, one VALUES UPDATE per 500 repoints, one insert_all per 500
  # tombstones, one insert_all per 2,000 link-rewrite jobs.
  #
  # Same contract as the per-item loop: all-or-nothing, and the #614 rule
  # that each repoint and its old-path tombstone share ONE seq (distinct
  # items get distinct seqs). A target held by ANY live row is a conflict,
  # including a row that is itself moving in this batch: one UPDATE cannot
  # order a chain of moves past the live-path unique index. `on_error.(reason,
  # old_path)` shapes the error so each surface keeps its own contract (bare
  # `:conflict` for folder rename, `{:conflict, path}` for `batch_move`).
  # Returns `{:ok, count}` | `{:error, _}`.
  #
  # `missing:` is what a source that is no longer live means. `:refuse` (a
  # user's explicit `batch_move/4`) fails the batch, as before. `:skip` (the
  # folder-rename cascade, whose pairs were scanned BEFORE its transaction,
  # #2159) drops it and logs how many: a file deleted or moved by a syncing
  # client in that window must not fail the whole folder rename.
  defp move_pairs(user, vault, pairs, on_error, missing \\ :refuse)

  defp move_pairs(_user, _vault, [], _on_error, _missing), do: {:ok, 0}

  defp move_pairs(user, vault, pairs, on_error, missing) do
    user = fresh_user(user)

    with {:ok, user} <- Crypto.ensure_user_dek(user),
         {:ok, dek} <- Crypto.get_dek(user),
         {:ok, filter_key} <- Crypto.dek_filter_key(user) do
      items =
        Enum.map(pairs, fn {old_path, new_path} ->
          old_path = PathSanitizer.sanitize(old_path)
          new_path = PathSanitizer.sanitize(new_path)

          %{
            old_path: old_path,
            new_path: new_path,
            old_hmac: Crypto.hmac_field(filter_key, old_path),
            new_hmac: Crypto.hmac_field(filter_key, new_path),
            old_basename_hmac: Crypto.hmac_field(filter_key, Links.basename_key(old_path)),
            new_basename_hmac: Crypto.hmac_field(filter_key, Links.basename_key(new_path))
          }
        end)

      Repo.with_tenant(user.id, fn ->
        # Vault first, then the source rows (LOCK ORDER, `Engram.Vaults`).
        :ok = Engram.Vaults.lock_seq!(vault.id)

        with {:ok, live, items} <- move_sources(user, vault, items, on_error, missing),
             moving = Enum.reject(items, &(&1.old_path == &1.new_path)),
             :ok <- move_targets_free(user, vault, moving, on_error) do
          moved = apply_moves(user, vault, {dek, filter_key}, moving, live)
          {:ok, {length(items), moved}}
        end
      end)
      |> unwrap_tenant()
      |> case do
        {:ok, {count, moved}} ->
          Enum.each(moved, fn {item, att} ->
            broadcast_attachment(user.id, vault.id, "delete", item.old_path, att)
            broadcast_attachment(user.id, vault.id, "upsert", item.new_path, att)
          end)

          {:ok, count}

        {:error, _} = err ->
          err
      end
    end
  end

  # Resolves each source to its live row. A source that is gone refuses the
  # batch (`:refuse`) or is dropped and counted (`:skip`).
  defp move_sources(user, vault, items, on_error, missing) do
    # FOR UPDATE: a delete committing between this read and the UPDATE would
    # make the UPDATE match one row fewer; locked, it waits for this commit.
    # The caller already holds the vault lock, so the order is vault, rows.
    live =
      from(a in scoped_live(user, vault),
        where: a.path_hmac in ^Enum.map(items, & &1.old_hmac),
        lock: "FOR UPDATE"
      )
      |> Repo.all()
      |> Map.new(&{&1.path_hmac, &1})

    {present, gone} = Enum.split_with(items, &Map.has_key?(live, &1.old_hmac))

    case {gone, missing} do
      {[], _} ->
        {:ok, live, present}

      {[item | _], :refuse} ->
        {:error, on_error.(:not_found, item.old_path)}

      {gone, :skip} ->
        require Logger

        Logger.warning(
          "folder rename: attachments skipped, deleted or moved after the scan",
          Metadata.with_category(:warning, :sync,
            user_id: user.id,
            vault_id: vault.id,
            total_count: length(gone)
          )
        )

        {:ok, live, present}
    end
  end

  defp move_targets_free(_user, _vault, [], _on_error), do: :ok

  defp move_targets_free(user, vault, moving, on_error) do
    new_hmacs = Enum.map(moving, & &1.new_hmac)

    held =
      from(a in scoped_live(user, vault), where: a.path_hmac in ^new_hmacs, select: a.path_hmac)
      |> Repo.all()
      |> MapSet.new()

    # Two pairs landing on one path conflict with each other too.
    {dupes, _} =
      Enum.reduce(new_hmacs, {MapSet.new(), MapSet.new()}, fn h, {d, seen} ->
        if MapSet.member?(seen, h), do: {MapSet.put(d, h), seen}, else: {d, MapSet.put(seen, h)}
      end)

    case Enum.find(
           moving,
           &(MapSet.member?(held, &1.new_hmac) or MapSet.member?(dupes, &1.new_hmac))
         ) do
      nil -> :ok
      item -> {:error, on_error.(:conflict, item.old_path)}
    end
  end

  # Returns `[{item, updated_attachment}]` for the broadcasts.
  defp apply_moves(_user, _vault, _keys, [], _live), do: []

  defp apply_moves(user, vault, {dek, filter_key}, moving, live) do
    now = DateTime.utc_now(:second)
    n = length(moving)
    last_seq = Engram.Vaults.next_seq_block!(vault.id, n)

    moved =
      moving
      |> Enum.with_index(last_seq - n + 1)
      |> Enum.map(fn {item, seq} ->
        att = Map.fetch!(live, item.old_hmac)

        {path_ct, path_n} =
          Envelope.encrypt(item.new_path, dek, Crypto.aad_for_row(:attachments, :path, att.id))

        cols =
          [
            path_ciphertext: path_ct,
            path_nonce: path_n,
            path_hmac: item.new_hmac,
            basename_hmac: item.new_basename_hmac
          ] ++ Links.path_keys(filter_key, item.new_path, path_n)

        {item, seq, cols, struct(%{att | path: item.new_path, updated_at: now, seq: seq}, cols)}
      end)

    ^n =
      BulkUpdate.move!(Enum.map(moved, fn {_i, seq, cols, att} -> {att.id, seq, cols} end), now)

    :ok = evict_counts(user.id)

    moved
    |> Enum.map(fn {item, seq, _cols, _att} ->
      tombstone_row(user, vault, dek, item, Map.fetch!(live, item.old_hmac), seq, now)
    end)
    |> Enum.chunk_every(BulkUpdate.chunk_size())
    |> Enum.each(&Repo.insert_all(Attachment, &1))

    # #648/#1231: rewrite referring notes' ![[...]]/[[...]] targets. In this
    # transaction, so the jobs roll back with the moves.
    moved
    |> Enum.map(fn {item, _seq, _cols, att} ->
      Engram.Workers.RewriteNoteLinks.new_for(
        user.id,
        vault.id,
        :attachment,
        att.id,
        Base.encode64(item.old_hmac),
        Base.encode64(item.old_basename_hmac)
      )
    end)
    |> Enum.chunk_every(2_000)
    |> Enum.each(&Oban.insert_all/1)

    Enum.map(moved, fn {item, _seq, _cols, att} -> {item, att} end)
  end

  # `tombstone_changeset/8` as an insert_all row.
  defp tombstone_row(user, vault, dek, item, live, seq, now) do
    user
    |> tombstone_changeset(
      vault,
      dek,
      item.old_path,
      {item.old_hmac, item.old_basename_hmac},
      live,
      seq,
      now
    )
    |> Ecto.Changeset.apply_action!(:insert)
    |> Map.take(Attachment.__schema__(:fields))
    |> Map.drop([:path, :content])
    |> Map.merge(%{created_at: now, updated_at: now})
  end

  # nil when the pair's target passes the blocklist (`Enum.find_value/3`).
  # A batch keeps basenames, so this refuses only a file stored while the
  # bypass was on; refused all-or-nothing, like the rest of the batch.
  defp blocked_target({_old, new_path}) do
    case check_move_target(new_path) do
      :ok -> nil
      err -> err
    end
  end

  # `batch_move/4`'s error shape: tag the offending path onto conflict/not_found,
  # pass any other reason through unchanged.
  defp tag_move_error(:conflict, old_path), do: {:conflict, old_path}
  defp tag_move_error(:not_found, old_path), do: {:not_found, old_path}
  defp tag_move_error(reason, _old_path), do: reason

  @doc """
  Cascades a folder rename across attachments: every live attachment whose path
  sits under `old_folder` moves to the mirrored path under `new_folder`,
  preserving nested structure. Per-item reuse of `move_attachment/4` (each item's
  repoint + old-path tombstone share one seq in one txn — the #614 discipline).
  All-or-nothing: a conflict/error on any item rolls back every prior DB write in
  the batch. Broadcasts already emitted self-heal on the next pull (same caveat as
  `batch_move/4`). Returns `{:ok, count}` (0 = no attachments, idempotent).
  """
  @spec rename_folder(Engram.Accounts.User.t(), map(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def rename_folder(user, vault, old_folder, new_folder) do
    with {:ok, pairs} <- folder_rename_pairs(user, vault, old_folder, new_folder),
         do: move_folder_pairs(user, vault, pairs)
  end

  @doc """
  The `[{old_path, new_path}]` moves a rename of `old_folder` to
  `new_folder` implies, from one decrypt scan. Split from `rename_folder/4`
  so `Engram.Folders` can run the scan BEFORE its transaction opens (#2159).
  """
  @spec folder_rename_pairs(map(), map(), String.t(), String.t()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def folder_rename_pairs(user, vault, old_folder, new_folder) do
    old_folder = String.trim_trailing(old_folder, "/")
    new_folder = String.trim_trailing(new_folder, "/")
    prefix = old_folder <> "/"
    old_len = String.length(old_folder)

    with {:ok, metas} <- list_attachments(user, vault) do
      {:ok,
       metas
       |> Enum.filter(&String.starts_with?(&1.path, prefix))
       |> Enum.map(fn %{path: old_path} ->
         {old_path, new_folder <> String.slice(old_path, old_len..-1//1)}
       end)}
    end
  end

  @doc """
  Atomically relocates a pre-built `[{old_path, new_path}]` list of attachment
  moves under ONE transaction. The folder-rename entry point for callers that
  have already scanned + filtered the vault (`rename_folder/4` for a single
  folder; `Engram.Folders` for a multi-folder batch — so the coordinator scans
  attachments ONCE and partitions across the N folder pairs rather than
  re-scanning per folder).

  Keeps BARE atoms (Bug 1) to match Notes.rename_folder/4's contract — the
  coordinator + REST + MCP callers match bare {:error, :conflict} /
  {:error, :not_found}; a tagged tuple here CaseClauseError'd → 500. So the shared
  `move_pairs/5` loop passes the raw reason through unchanged. A source that
  is no longer live (deleted or moved after the caller's scan) is skipped and
  logged, not a failure (#2159). Returns `{:ok, count}` of rows moved (0 = no
  pairs, idempotent).
  """
  @spec move_folder_pairs(map(), map(), [{String.t(), String.t()}]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def move_folder_pairs(user, vault, pairs) do
    move_pairs(user, vault, pairs, fn reason, _old_path -> reason end, :skip)
  end

  @doc """
  Cascades a folder delete across attachments: soft-deletes every live attachment
  whose path sits under `folder` (incl. nested). Reuses `batch_delete/3` so each
  delete broadcasts (its blob is left for `AttachmentBlobGC`). Returns `{:ok, count}` (0 =
  no attachments, idempotent).

  Seq note (DRY-by-design, diverges from a literal "one transaction under one
  seq"): `batch_delete/3` allocates a contiguous per-row seq block (each row
  gets its OWN seq) rather than a single batch-wide `seq`. Per-row seq is SAFE
  for deletes — the soft-deleted row itself is the change signal, so the #614
  same-seq cursor-skip concern (a moved row + its same-seq tombstone) simply does
  not arise (delete has no tombstone). Cross-table + cross-item atomicity is
  NOT provided (#2159): each chunk commits on its own, so a mid-loop failure
  keeps the chunks before it and a retry finishes the rest. Reusing `batch_delete/3` keeps
  one delete path instead of a bespoke single-seq `update_all`.
  """
  # Cheap request-size guard (chunk-stamping and the legacy feed it protected
  # are gone; no bulk consumer exceeds this). Defined once, above every use:
  # Elixir reads module attributes at their point of use, so a second
  # definition would silently give the chunker and the batch_delete guard
  # different limits.
  @max_batch_entries 500

  @spec delete_folder(Engram.Accounts.User.t(), map(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def delete_folder(user, vault, folder) do
    with {:ok, %{paths: paths}} <- scan_folder_paths(user, vault, folder) do
      delete_scanned_paths(user, vault, paths)
    end
  end

  @doc """
  Live attachment paths under `folder`, plus how many rows could NOT be read.

  Returns `%{paths: [...], undecryptable: n}` from ONE scan, so the
  folder-delete guard can count and then delete the same rows.

  `undecryptable` is vault-wide and CANNOT be narrowed to the folder: a row
  whose path fails to decrypt has no readable path, so there is no way to tell
  whether it lives here. That is the whole point — it is unknown, not absent.
  Reporting the count lets the caller decide, which is the only correct split
  of responsibility. An earlier revision refused outright whenever any row in
  the vault was unreadable, which bricked EVERY folder delete (including
  `recursive: true`) over one corrupt row somewhere else entirely.
  """
  @spec scan_folder_paths(map(), map(), String.t()) ::
          {:ok, %{paths: [String.t()], undecryptable: non_neg_integer()}} | {:error, term()}
  def scan_folder_paths(user, vault, folder) do
    prefix = String.trim_trailing(folder, "/") <> "/"

    with {:ok, rows, metas} <- scan_attachments(user, vault) do
      {:ok,
       %{
         paths: metas |> Enum.map(& &1.path) |> Enum.filter(&String.starts_with?(&1, prefix)),
         undecryptable: length(rows) - length(metas)
       }}
    end
  end

  @doc """
  Rows per transaction in a folder delete cascade (#2159), for both the
  attachment and the notes legs. Capped at `batch_delete/3`'s limit;
  `:folder_delete_chunk` lowers it (tests).
  """
  @spec delete_chunk_size() :: pos_integer()
  def delete_chunk_size,
    do:
      min(
        Application.get_env(:engram, :folder_delete_chunk, @max_batch_entries),
        @max_batch_entries
      )

  @doc """
  Soft-deletes the paths produced by `scan_folder_paths/3`, in sorted order,
  one `batch_delete/3` transaction per `delete_chunk_size/0` chunk. Each
  chunk commits on its own (#2159): a failure keeps the chunks before it,
  and a retry rescans and deletes the rest. Returns the count.
  """
  # No error branch: `batch_delete/3` is hard-matched below, so this either
  # returns a count or raises.
  @spec delete_scanned_paths(map(), map(), [String.t()], keyword()) :: {:ok, non_neg_integer()}
  def delete_scanned_paths(user, vault, paths, opts \\ []) do
    deleted =
      paths
      |> Enum.sort()
      |> Enum.chunk_every(delete_chunk_size())
      |> Enum.reduce(0, fn chunk, acc ->
        {:ok, %{deleted: n}} = batch_delete(user, vault, chunk, opts)
        acc + n
      end)

    {:ok, deleted}
  end

  @doc """
  Soft-deletes each attachment by path. Idempotent. `:deleted` counts paths that
  actually held a live row (absent/already-deleted paths don't count).

  ONE transaction for the whole batch (was one per path): resolve every
  path_hmac up front, allocate a contiguous per-row seq block from the vault
  counter, soft-delete via a single VALUES-join UPDATE, then run the
  post-commit side effects: the same per-path `note_changed` delete broadcast
  `do_delete_attachment/4` emits (payload shape identical; batch calls carry
  no origin device, same as before). Blobs stay for
  `Engram.Workers.AttachmentBlobGC` (#2159).

  Capped at 500 paths per batch (`{:error, :batch_too_large}` above that).
  `op_id:` stamps every row it deletes with that undo id (#609).
  """
  @spec batch_delete(map(), map(), [String.t()], keyword()) ::
          {:ok, %{deleted: non_neg_integer()}} | {:error, :batch_too_large}
  def batch_delete(user, vault, paths, opts \\ [])

  def batch_delete(_user, _vault, [], _opts), do: {:ok, %{deleted: 0}}

  def batch_delete(_user, _vault, paths, _opts)
      when is_list(paths) and length(paths) > @max_batch_entries,
      do: {:error, :batch_too_large}

  def batch_delete(user, vault, paths, opts) when is_list(paths) do
    user = fresh_user(user)

    case Crypto.dek_filter_key(user) do
      {:ok, filter_key} ->
        sanitized = paths |> Enum.map(&PathSanitizer.sanitize/1) |> Enum.uniq()
        hmac_by_path = Map.new(sanitized, &{&1, Crypto.hmac_field(filter_key, &1)})

        # batch_soft_delete_rows never returns {:error, _}: a DB failure
        # RAISES (Repo.query! inside the tenant transaction), rolling back
        # the WHOLE batch. All-or-nothing is deliberate — a change from the
        # old per-path independent transactions — and callers see the raise,
        # never a fake `deleted: 0` success.
        {:ok, {deleted_ids, deleted_hmacs}} =
          batch_soft_delete_rows(user, vault, Map.values(hmac_by_path), opts[:op_id])

        # One broadcast per deleted path in input order. No blob delete
        # (#2159): this can run nested in a folder cascade that still rolls
        # back, and a deleted blob cannot.
        if deleted_ids != [], do: :ok = evict_counts(user.id)

        deleted_set = MapSet.new(deleted_hmacs)

        for path <- sanitized, MapSet.member?(deleted_set, hmac_by_path[path]) do
          Broadcast.emit("sync:#{user.id}:#{vault.id}", "note_changed", %{
            "event_type" => "delete",
            "kind" => "attachment",
            "path" => path,
            "vault_id" => vault.id
          })
        end

        {:ok, %{deleted: length(deleted_hmacs)}}

      {:error, :no_dek} ->
        # No DEK = no attachments to delete; mirror do_delete_attachment.
        {:ok, %{deleted: 0}}
    end
  end

  # One tenant transaction for the whole batch: find the live rows, allocate a
  # contiguous seq block (one vault-counter UPDATE — same row lock
  # `Vaults.next_seq!/1` takes, so per-vault allocation stays serialized), and
  # soft-delete every row via a single VALUES-join UPDATE that stamps each row
  # its OWN seq (the `(seq, id)` keyset feed requires per-row-distinct,
  # monotonic seqs — N rows must never share one). Returns
  # `{:ok, {deleted_ids, deleted_path_hmacs}}` for the actually-deleted rows.
  defp batch_soft_delete_rows(_user, _vault, [], _op_id), do: {:ok, {[], []}}

  defp batch_soft_delete_rows(user, vault, hmacs, op_id) do
    now = DateTime.utc_now(:second)

    Repo.with_tenant(user.id, fn ->
      rows =
        from(a in scoped_live(user, vault),
          where: a.path_hmac in ^hmacs,
          order_by: a.id,
          select: {a.id, a.path_hmac}
        )
        |> Repo.all()

      if rows == [] do
        {[], []}
      else
        n = length(rows)
        last_seq = Engram.Vaults.next_seq_block!(vault.id, n)

        id_seqs =
          rows
          |> Enum.with_index(last_seq - n + 1)
          |> Enum.map(fn {{id, _hmac}, seq} -> {id, seq} end)

        returned = BulkUpdate.stamp_seqs!(id_seqs, :delete, now)
        deleted_ids = Enum.map(returned, &elem(&1, 0))

        # A second statement rather than a column in `stamp_seqs!`'s VALUES:
        # same transaction, and it keeps that file's pinned Sobelow lines put.
        _ =
          if op_id do
            {_n, _} =
              Repo.update_all(from(a in Attachment, where: a.id in ^deleted_ids),
                set: [delete_op_id: op_id]
              )
          end

        deleted_hmacs = returned |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
        {deleted_ids, deleted_hmacs}
      end
    end)
    |> unwrap_tenant()
  end

  # A live row's blob is missing: queue a restore from bucket versions for
  # its vault (#2159). After commit, and deduped per vault for 10 minutes, so
  # a client reading thousands of them queues one job.
  defp reconcile_blobs(%Attachment{user_id: user_id, vault_id: vault_id}),
    do: Repo.after_commit(fn -> ReconcileAttachmentBlobs.enqueue(user_id, vault_id) end)

  # Live rows carry `content_hash` (#2159), the same HMAC the single GET
  # returns: a client compares it with its local copy to skip a download, or
  # to re-push its bytes when the server lost the blob. Already loaded with
  # the row, so it costs one field per feed row, no extra read.
  defp put_live_content_hash(meta, %Attachment{deleted_at: nil, content_hash: hash}),
    do: Map.put(meta, :content_hash, hash)

  defp put_live_content_hash(meta, _att), do: meta

  @doc """
  Gives each live row in `ids` a fresh seq (one contiguous block), so sync
  clients pull it again. Used after its blob is restored
  (`Engram.Workers.ReconcileAttachmentBlobs`). Returns how many rows moved.
  """
  @spec bump_seqs(String.t(), String.t(), [String.t()]) :: non_neg_integer()
  def bump_seqs(_user_id, _vault_id, []), do: 0

  def bump_seqs(user_id, vault_id, ids) do
    now = DateTime.utc_now(:second)

    Repo.with_tenant!(user_id, fn ->
      last_seq = Engram.Vaults.next_seq_block!(vault_id, length(ids))

      ids
      |> Enum.sort()
      |> Enum.with_index(last_seq - length(ids) + 1)
      |> BulkUpdate.stamp_seqs!(:touch, now)
      |> length()
    end)
  end

  @doc """
  Brings soft-deleted rows `ids` back to life with a fresh seq each (#2195).
  The only undelete path for attachments: every restore goes through here.

  Takes the vault row lock first (`next_seq_block!/2`), the same lock
  `Engram.Workers.AttachmentBlobGC` claims under, so the two serialize. A row
  is revived only if it still holds its `storage_key`, carries NO GC claim at
  all, and no live row holds its path. A stale claim is refused too: it only
  says the GC run died, not before or after its S3 delete, so the blob may
  be gone. That costs nothing, since the GC only claims rows already past
  their owner's retention; its next run re-claims and finalizes the row. Everything else comes back in `unrestored`, so a
  restore either has its blob or is refused; it never leaves a live row
  pointing at nothing.

  Returns `{:ok, %{restored: ids, unrestored: ids}}`. Broadcasting is the
  caller's (it has the decrypted paths).
  """
  @spec revive_tombstones(map(), map(), [String.t()]) ::
          {:ok, %{restored: [String.t()], unrestored: [String.t()]}} | {:error, term()}
  def revive_tombstones(_user, _vault, []), do: {:ok, %{restored: [], unrestored: []}}

  def revive_tombstones(user, vault, ids) do
    ids = Enum.uniq(ids)
    now = DateTime.utc_now(:second)

    Repo.with_tenant(user.id, fn ->
      # The lock BEFORE the eligibility read, or a claim that commits in
      # between is invisible to it.
      last_seq = Engram.Vaults.next_seq_block!(vault.id, length(ids))

      {_n, revived} =
        Repo.update_all(
          from(a in scoped(user, vault),
            as: :tomb,
            where:
              a.id in ^ids and not is_nil(a.deleted_at) and not is_nil(a.storage_key) and
                is_nil(a.blob_gc_claimed_at) and
                not exists(
                  from(l in Attachment,
                    where:
                      l.user_id == parent_as(:tomb).user_id and
                        l.vault_id == parent_as(:tomb).vault_id and
                        l.path_hmac == parent_as(:tomb).path_hmac and is_nil(l.deleted_at),
                    select: 1
                  )
                ),
            select: a.id
          ),
          set: [deleted_at: nil, delete_op_id: nil, updated_at: now]
        )

      # Now live, so `stamp_seqs!`'s live-row guard admits them. Unused seqs
      # in the block are gaps, which the feed allows.
      _ =
        revived
        |> Enum.sort()
        |> Enum.with_index(last_seq - length(ids) + 1)
        |> BulkUpdate.stamp_seqs!(:touch, now)

      if revived != [], do: :ok = evict_counts(user.id)
      %{restored: revived, unrestored: ids -- revived}
    end)
    |> unwrap_tenant()
  end

  # Real-time parity: reuse the existing `note_changed` socket event the plugin
  # already dispatches by `kind`. A move fires delete(old) + upsert(new), like
  # Notes.rename. Receive-only on the plugin — it still pushes over HTTP.
  defp broadcast_attachment(user_id, vault_id, event_type, path, %Attachment{} = att) do
    payload = %{
      "event_type" => event_type,
      "kind" => "attachment",
      "path" => path,
      "vault_id" => vault_id,
      "mime_type" => att.mime_type,
      "size_bytes" => att.size_bytes,
      "mtime" => att.mtime,
      # Engram#961 (1). Without this a peer that ALREADY holds these exact
      # bytes has to GET the whole attachment — possibly many MB — purely to
      # byte-compare and learn nothing changed. The value was in hand at every
      # emit site; it just was not sent. Same value the REST endpoints serve,
      # so a client can compare the two directly.
      "content_hash" => att.content_hash
    }

    _ = Broadcast.emit("sync:#{user_id}:#{vault_id}", "note_changed", with_row_id(payload, att))
    :ok
  end

  # Upserts carry the row's id and updated_at: the web app builds a tree row
  # from them for a path it has never seen, instead of re-fetching the whole
  # vault tree once per upload. NOT on deletes: the plugin treats a delete's
  # `id` as the NOTE id it addresses and keys CRDT room teardown on it.
  defp with_row_id(%{"event_type" => "upsert"} = payload, att),
    do: Map.merge(payload, %{"id" => att.id, "updated_at" => att.updated_at})

  defp with_row_id(payload, _att), do: payload

  @doc """
  Lists non-deleted attachment metadata for a vault (no content).
  """
  def list_attachments(user, vault) do
    with {:ok, _rows, metas} <- scan_attachments(user, vault), do: {:ok, metas}
  end

  @doc """
  Like `list_attachments/2`, but refuses to answer when any row fails to decrypt.

  `decrypt_each/3` is deliberately tolerant — one corrupt attachment must not
  make a whole vault unlistable. That is right for DISPLAY and wrong for a
  caller about to make a destructive decision from the result: a short list is
  indistinguishable from a short folder, so the folder-delete emptiness guard
  read "N rows I cannot decrypt" as "empty" and cascaded over them. Callers
  that count in order to decide whether to delete use this instead.
  """
  @spec list_attachments_strict(map(), map()) ::
          {:ok, [map()]} | {:error, {:undecryptable_attachments, pos_integer()} | term()}
  def list_attachments_strict(user, vault) do
    with {:ok, rows, metas} <- scan_attachments(user, vault) do
      case length(rows) - length(metas) do
        0 -> {:ok, metas}
        dropped -> {:error, {:undecryptable_attachments, dropped}}
      end
    end
  end

  @doc """
  One scan: decrypted metas plus the number of rows that would not decrypt.

  `{:ok, metas, dropped}`. For callers that must not mistake "could not read
  it" for "it is not there" — see `list_attachments_strict/2`.
  """
  @spec scan_with_drops(map(), map()) :: {:ok, [map()], non_neg_integer()} | {:error, term()}
  def scan_with_drops(user, vault) do
    with {:ok, rows, metas} <- scan_attachments(user, vault) do
      {:ok, metas, length(rows) - length(metas)}
    end
  end

  # decrypt_metadata/2 (via maybe_decrypt_attachment_fields/2) and the
  # extra.() closure below only ever read these columns — everything else on
  # the schema (ciphertext/nonce/hmac fields besides path, storage_key,
  # version, seq, dek_version_pending, ...) was dead weight on the wire and
  # in the decode step. `struct(a, fields)` keeps a real %Attachment{}
  # struct (decrypt_aad/3 pattern-matches `%_{dek_version: v}`), just with
  # only these fields populated.
  @tree_attachment_fields ~w(id dek_version path_ciphertext path_nonce mime_type size_bytes mtime updated_at content_hash)a

  # Returns the raw rows alongside the decrypted metas so a caller can tell
  # whether `decrypt_each/3` dropped any of them. Each skip is already logged
  # there; this only makes the drop visible in the return value.
  defp scan_attachments(user, vault) do
    user = fresh_user(user)

    Repo.with_tenant(user.id, fn -> raw_tree_rows(user, vault) end)
    |> unwrap_tenant()
    |> case do
      {:ok, atts} -> {:ok, atts, decrypt_tree_rows(atts, user)}
      err -> err
    end
  end

  @doc """
  Raw attachment rows for GET /vault/tree, projected to the columns
  `decrypt_tree_rows/2` (and every current caller of `list_attachments/2`)
  actually reads. MUST run inside the caller's `Repo.with_tenant/2` — pair
  with `decrypt_tree_rows/2`, which does the decrypt work OUTSIDE any
  transaction. See `Notes.raw_tree_note_rows/2` for the notes equivalent,
  and #1211 for why decrypt must stay outside the transaction.
  """
  @spec raw_tree_rows(map(), map()) :: [Attachment.t()]
  def raw_tree_rows(user, vault) do
    from(a in scoped_live(user, vault),
      order_by: [asc: a.updated_at],
      select: struct(a, @tree_attachment_fields)
    )
    |> Repo.all()
  end

  @doc """
  Decrypts `raw_tree_rows/2`'s rows into the same meta shape
  `list_attachments/2` returns (id/path/mime_type/size_bytes/mtime/
  updated_at/content_hash). Skips and logs any row that fails to decrypt —
  same tolerant behavior as `list_attachments/2`. Does no DB access; meant
  to run OUTSIDE any transaction.
  """
  @spec decrypt_tree_rows([Attachment.t()], map()) :: [map()]
  def decrypt_tree_rows(atts, user) do
    # Reload if the caller's struct predates an earlier write's DEK
    # provisioning — same discipline scan_attachments/2 applies before its
    # own decrypt_each call, now enforced here instead of trusting every
    # caller (e.g. VaultTreeController) to remember it.
    user = fresh_user(user)

    # Measured like every other bulk path decrypt (:notes, :vault_tree_notes,
    # :manifest_*). Label is caller-agnostic — per-endpoint attribution comes
    # from the OTel request span, not this tag.
    Crypto.measure_decrypt_batch(:attachments, length(atts), fn ->
      decrypt_batch(atts, user, fn att, meta ->
        # content_hash rides along so the listing a client sweeps before
        # deciding what to push can answer "you already have these bytes"
        # without a per-file round trip. Additive for every other caller.
        meta
        |> Map.delete(:deleted_at)
        |> Map.put(:id, att.id)
        |> Map.put(:content_hash, att.content_hash)
      end)
    end)
  end

  @doc """
  The attachments half of `Engram.Folders.restore_op/3`, read-only: the rows
  op `op_id` tombstoned in this vault, split into what can come back and what
  is skipped (`:path_taken` when a live attachment holds the path,
  `:expired` when deleted before `cutoff`, past trash retention).

  Refuses with `{:error, {:limit_reached, :attachment_bytes_cap, limit,
  used}}` when the restorable bytes would take the user past their quota.
  """
  @spec plan_restore(map(), map(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, %{attachments: [map()], skipped: [map()]}} | {:error, term()}
  def plan_restore(user, vault, op_id, cutoff) do
    user = fresh_user(user)

    with {:ok, rows} <-
           Repo.with_tenant(user.id, fn ->
             Repo.all(
               from(a in scoped(user, vault),
                 where: a.delete_op_id == ^op_id and not is_nil(a.deleted_at),
                 select: struct(a, [:deleted_at, :path_hmac | @tree_attachment_fields])
               )
             )
           end)
           |> unwrap_tenant() do
      {rows, expired} = Enum.split_with(rows, &(DateTime.compare(&1.deleted_at, cutoff) != :lt))
      hmac_of = Map.new(rows, &{&1.id, &1.path_hmac})
      metas = Enum.map(decrypt_tree_rows(rows, user), &Map.put(&1, :path_hmac, hmac_of[&1.id]))
      taken = live_hmacs(user, vault, Map.values(hmac_of))
      {taken, free} = Enum.split_with(metas, &MapSet.member?(taken, &1.path_hmac))
      bytes = free |> Enum.map(& &1.size_bytes) |> Enum.sum()

      case validate_storage_cap(user, nil, bytes) do
        :ok ->
          {:ok,
           %{
             attachments: free,
             skipped:
               Enum.map(taken, &%{path: &1.path, kind: "attachment", reason: :path_taken}) ++
                 Enum.map(expired, &%{id: &1.id, kind: "attachment", reason: :expired})
           }}

        {:error, {:storage_cap_reached, used, limit}} ->
          {:error, {:limit_reached, :attachment_bytes_cap, limit, used}}
      end
    end
  end

  defp live_hmacs(_user, _vault, []), do: MapSet.new()

  defp live_hmacs(user, vault, hmacs) do
    Repo.with_tenant!(user.id, fn ->
      Repo.all(
        from(a in scoped_live(user, vault), where: a.path_hmac in ^hmacs, select: a.path_hmac)
      )
    end)
    |> MapSet.new()
  end

  @doc """
  Brings back `metas` (from `plan_restore/4`) through `revive_tombstones/3`,
  in chunks, and announces each restored path. Rows the revive refuses (blob
  reaped or mid-reap, path taken since the plan) come back as skipped
  `:unavailable`.
  """
  @spec restore_attachments(map(), map(), [map()]) ::
          {:ok, %{restored: [String.t()], skipped: [map()]}} | {:error, term()}
  def restore_attachments(user, vault, metas) do
    metas
    |> Enum.chunk_every(delete_chunk_size())
    |> Enum.reduce_while({:ok, %{restored: [], skipped: []}}, fn chunk, {:ok, acc} ->
      case revive_tombstones(user, vault, Enum.map(chunk, & &1.id)) do
        {:ok, %{restored: ids}} ->
          back = MapSet.new(ids)
          {restored, refused} = Enum.split_with(chunk, &MapSet.member?(back, &1.id))
          now = DateTime.utc_now(:second)

          for m <- restored do
            att =
              struct(Attachment, Map.put(Map.take(m, @tree_attachment_fields), :updated_at, now))

            broadcast_attachment(user.id, vault.id, "upsert", m.path, att)
          end

          {:cont,
           {:ok,
            %{
              restored: acc.restored ++ Enum.map(restored, & &1.path),
              skipped:
                acc.skipped ++
                  Enum.map(refused, &%{path: &1.path, kind: "attachment", reason: :unavailable})
            }}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  @doc """
  Lists attachment metadata directly inside `folder` (non-recursive), mirroring
  `Notes.list_notes_in_folder/3`. Root is `""`. Returns `{:ok, metas}`.
  """
  @spec list_in_folder(map(), map(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_in_folder(user, vault, folder) do
    with {:ok, metas} <- list_attachments(user, vault) do
      {:ok, Enum.filter(metas, fn m -> attachment_folder(m.path) == folder end)}
    end
  end

  defp attachment_folder(path) do
    case Path.dirname(path) do
      "." -> ""
      dir -> dir
    end
  end

  @doc """
  Seq-cursor change feed over attachments: rows with `(seq, id) > (after_seq,
  after_id)`, ordered by `(seq, id)`, paginated. Mirrors
  `Engram.Notes.list_changes_by_seq/4`.

  Carries the FULL change set — tombstones included (no `deleted_at` filter) so
  deletes flow through the unified `/sync/changes` pull. Per-vault `seq` is
  monotonic and unique, so `(seq, id)` is a stable keyset that never loses or
  duplicates rows across pages.

  Options:

    * `after_id:` — the keyset tiebreak id from the previous page's `next`
      (the `id` component); required to resume mid-`seq`, harmless otherwise.
    * `limit:` — page size, clamped to 1..500 (default 500).

  Each change entry carries `:id`, `:seq`, `:version`, `:deleted`
  (`deleted_at != nil`), plus `:path`, `:mime_type`, `:size_bytes`, `:mtime`,
  `:updated_at`. Returns
  `{:ok, %{changes: [...], has_more: bool, next: {seq, id} | nil}}`.
  """
  @spec list_changes_by_seq(map(), map(), integer(), keyword()) ::
          {:ok, %{changes: [map()], has_more: boolean(), next: {integer(), binary()} | nil}}
          | {:error, term()}
  def list_changes_by_seq(user, vault, after_seq, opts \\ []) when is_integer(after_seq) do
    user = fresh_user(user)
    limit = opts |> Keyword.get(:limit, 500) |> min(500) |> max(1)
    after_id = Keyword.get(opts, :after_id)

    base =
      from(a in scoped(user, vault),
        where: not is_nil(a.seq),
        order_by: [asc: a.seq, asc: a.id],
        limit: ^(limit + 1)
      )

    base =
      if after_id do
        # A row comparison, not `seq > s OR (seq = s AND id > i)`: only this
        # form is an index range on (vault_id, seq, id), so a page seeks to its
        # cursor instead of walking the feed from seq 0 (SeqFeedKeysetPlanTest).
        from(a in base,
          where: fragment("(?, ?) > (?, ?)", a.seq, a.id, ^after_seq, type(^after_id, Ecto.UUID))
        )
      else
        from(a in base, where: a.seq > ^after_seq)
      end

    Repo.with_tenant(user.id, fn -> Repo.all(base) end)
    |> unwrap_tenant()
    |> case do
      {:ok, atts} ->
        {page, has_more} =
          if length(atts) > limit, do: {Enum.take(atts, limit), true}, else: {atts, false}

        changes =
          decrypt_each(page, user, fn att, meta ->
            meta
            |> Map.put(:id, att.id)
            |> Map.put(:seq, att.seq)
            |> Map.put(:version, att.version)
            |> Map.put(:deleted, not is_nil(att.deleted_at))
            |> put_live_content_hash(att)
            |> Map.delete(:deleted_at)
          end)

        next =
          if has_more do
            last = List.last(page)
            {last.seq, last.id}
          end

        {:ok, %{changes: changes, has_more: has_more, next: next}}

      err ->
        err
    end
  end

  @doc """
  Returns storage usage for a vault: total bytes and file count.
  """
  def storage_usage(user, vault) do
    Repo.with_tenant(user.id, fn ->
      from(a in scoped_live(user, vault),
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

  @doc """
  The lifetime-quota check for an upload whose size is known before its bytes
  are, so a raw upload over quota is refused without reading the body. The
  authoritative check inside `upsert_attachment/3` still runs; this only
  answers early, and only when that check is certain to refuse:

    * the same arithmetic (`validate_storage_cap/3`, net of the live file at
      `path`), so it is never stricter;
    * never when the file at `path` has the same size: those may be the same
      bytes, which the upsert answers as a no-op 200 even over quota.

  The common case costs one usage query; the existing-file lookup runs only
  when the upload would not fit on top of current usage.
  """
  @spec check_storage_cap(map(), map(), String.t(), non_neg_integer()) ::
          :ok | {:error, {:storage_cap_reached, integer(), integer()}}
  def check_storage_cap(user, vault, path, size) do
    with n when is_integer(n) and n >= 0 <- Billing.effective_limit(user, :attachment_bytes_cap),
         {:ok, %{used_bytes: used}} when used + size > n <- storage_usage(user),
         {:ok, existing} <- existing_at(user, vault, path),
         false <- same_size?(existing, size) do
      validate_storage_cap(user, existing, size)
    else
      _ -> :ok
    end
  end

  # A key error stands the early check down rather than guessing "no file to
  # net out", which is the stricter answer.
  defp existing_at(user, vault, path) do
    with {:ok, user} <- Crypto.ensure_user_dek(user),
         {:ok, filter_key} <- Crypto.dek_filter_key(user) do
      path_hmac = Crypto.hmac_field(filter_key, PathSanitizer.sanitize(path))
      {:ok, fetch_existing(user, vault.id, path_hmac)}
    end
  end

  defp same_size?(%Attachment{size_bytes: size}, size), do: true
  defp same_size?(_existing, _size), do: false

  # -- Private helpers --

  # Pricing v2 §G — per-plan max_file_bytes via `Engram.Billing`. When
  # limits aren't enforced (self-host without Paddle), `effective_limit`
  # returns `:unlimited` and uploads are unbounded — operator's call.
  @doc false
  def validate_size(size, user) when is_integer(size) do
    case Billing.effective_limit(user, :max_file_bytes) do
      # A NEGATIVE limit is the "unlimited" sentinel (check_limit/3,
      # normalize_capability/2, Billing.plan_state/1), never a real ceiling.
      # Without this clause an operator lifting the cap with -1 rejects EVERY
      # upload as {:too_large, -1} — and since the client is told the limit is
      # nil, its own pre-gate passes and the rejection arrives unexplained.
      n when is_integer(n) and n < 0 -> :ok
      n when is_integer(n) and size > n -> {:error, {:too_large, n}}
      _ -> :ok
    end
  end

  # Pricing v2 §G — per-plan attachment_bytes_cap (lifetime quota).
  # Compute the net new total: current sum minus the existing row's
  # size (if upserting) plus the new payload size. Sum is scoped to
  # non-deleted rows via storage_usage/1. Runs inside the per-path
  # advisory lock for consistency with the writer's view of `existing`.
  @doc false
  def validate_storage_cap(user, existing, new_size) do
    case Billing.effective_limit(user, :attachment_bytes_cap) do
      # Same unlimited sentinel as validate_size/2 above.
      n when is_integer(n) and n < 0 ->
        :ok

      n when is_integer(n) ->
        {:ok, %{used_bytes: current}} = storage_usage(user)
        prior = if existing, do: existing.size_bytes, else: 0

        if current - prior + new_size > n,
          do: {:error, {:storage_cap_reached, current, n}},
          else: :ok

      _ ->
        :ok
    end
  end

  defp prepare_upload(
         user,
         vault,
         {att_id, key},
         path,
         hmacs,
         plaintext,
         mtime,
         explicit_mime
       ) do
    mime = explicit_mime || MimeWhitelist.detect_mime(path)

    with {:ok, dek} <- Crypto.get_dek(user),
         {:ok, content_key} <- Crypto.dek_content_hash_key(user) do
      hash = Crypto.hmac_content_hash(content_key, plaintext)
      content_aad = Crypto.aad_for_row(:attachments, :content, att_id)
      {ciphertext, nonce} = Envelope.encrypt(plaintext, dek, content_aad)

      attrs =
        %{
          content_hash: hash,
          mime_type: mime,
          size_bytes: byte_size(plaintext),
          mtime: mtime,
          user_id: user.id,
          vault_id: vault.id,
          storage_key: key,
          deleted_at: nil,
          encryption_version: 1,
          dek_version: Crypto.row_version_aad_bound(),
          content_nonce: nonce,
          # Clears a segmented (v2) row's fields when this replaces one.
          wrapped_file_key: nil,
          file_key_nonce: nil,
          upload_id: nil,
          segment_size: nil,
          segment_count: nil
        }
        |> Map.merge(path_attrs(dek, att_id, path, hmacs))

      {:ok, attrs, ciphertext}
    end
  end

  @doc false
  # The path columns of an attachment row: ciphertext bound to `att_id`, the
  # lookup HMACs, and the link-resolution keys.
  @spec path_attrs(binary(), Ecto.UUID.t(), String.t(), {binary(), binary()}) :: map()
  def path_attrs(dek, att_id, path, {path_hmac, basename_hmac}) do
    path_aad = Crypto.aad_for_row(:attachments, :path, att_id)
    {path_ct, path_n} = Envelope.encrypt(path, dek, path_aad)

    Map.merge(
      %{
        path_ciphertext: path_ct,
        path_nonce: path_n,
        path_hmac: path_hmac,
        basename_hmac: basename_hmac
      },
      Map.new(Links.path_keys(Crypto.dek_filter_key_from_bytes(dek), path, path_n))
    )
  end

  defp store_external(key, binary, mime) do
    case Storage.adapter().put(key, binary, content_type: mime) do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger
        # safe_reason/1, not inspect/1. `storage_key` above is redacted by key, but
        # this value is not — `:reason` is absent from RedactFilter's set, and it
        # goes into the message BODY as well, which nothing filters. For legacy
        # `key` comes from the storage_key column, so an
        # ExAws error that echoes the key would print the path.
        reason_str = Metadata.safe_reason(reason)

        # Reason is inlined into the message (not only metadata) so it's visible
        # in dev too — config/dev.exs strips Logger metadata from the formatter.
        Logger.error(
          "attachment storage PUT failed: #{reason_str}",
          Metadata.with_category(:error, :sync,
            storage_key: key,
            reason: reason_str
          )
        )

        {:error, {:storage, reason}}
    end
  end

  # Reload the user from DB if the in-memory struct doesn't reflect a DEK that
  # was provisioned by an earlier write (the writer's user struct doesn't
  # mutate the caller's). Read paths use this before any DEK derivation.
  defp fresh_user(user), do: Crypto.fresh_user(user)

  defp decrypt(%Attachment{content_nonce: nonce} = att, ciphertext, user) do
    aad =
      if is_integer(att.dek_version) and att.dek_version >= 2,
        do: Crypto.aad_for_row(:attachments, :content, att.id),
        else: <<>>

    with {:ok, dek} <- Crypto.get_dek(fresh_user(user)),
         {:ok, plaintext} <- Envelope.decrypt(ciphertext, nonce, dek, aad) do
      {:ok, %{att | content: plaintext}}
    else
      :error -> {:error, :decrypt_failed}
      {:error, _} -> {:error, :decrypt_failed}
    end
  end

  # `:content` is an atom key on purpose: request params are string-keyed, so
  # a client cannot smuggle it in through the JSON body or the query string.
  # Only the controller's raw-body branch sets it, after a bounded read.
  defp attachment_bytes(%{content: bytes}) when is_binary(bytes), do: {:ok, bytes}

  # compat(plugin): raw_attachment_upload - remove when plugin floor includes Engram-obsidian#555 (#1877)
  # The base64 JSON upload from plugins that predate raw bodies. Costs ~140 ms
  # decode + ~75 ms JSON parse per 10 MB on a normal scheduler.
  defp attachment_bytes(attrs),
    do: decode_base64(attrs["content_base64"] || attrs[:content_base64])

  defp decode_base64(nil), do: {:error, :missing_content}

  defp decode_base64(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, :invalid_base64}
    end
  end

  # Returns {:ok, metadata} or {:error, reason}. Callers SKIP + log on error so a
  # single undecryptable ("poison") row — e.g. AAD mismatch after a botched DEK
  # rotation — doesn't crash the whole list and blank every attachment in the
  # vault.
  defp decrypt_metadata(att, user) do
    case Crypto.maybe_decrypt_attachment_fields(att, user) do
      {:ok, decrypted} -> {:ok, metadata(decrypted)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp metadata(att) do
    %{
      path: att.path,
      mime_type: att.mime_type,
      size_bytes: att.size_bytes,
      mtime: att.mtime,
      updated_at: att.updated_at,
      deleted_at: att.deleted_at
    }
  end

  # One NIF call for the whole list (the same batch the sync manifest uses)
  # instead of a get_dek + NIF round trip per row. The AAD per row is the one
  # decrypt_aad/3 builds: the row's own id when dek_version >= the bound
  # version, empty for legacy rows. Any failure (a corrupt or mis-bound row,
  # a nil-ciphertext legacy row, no DEK) falls back to decrypt_each/3, so the
  # skip-and-log behavior and every result stay exactly what they were.
  # ponytail: one bad row costs the vault the old per-row path on every read;
  # split the batch around it if that ever shows up in the decrypt metrics.
  defp decrypt_batch(atts, user, extra) do
    with true <- Enum.all?(atts, &is_binary(&1.path_ciphertext)),
         {:ok, dek} <- Crypto.get_dek(user),
         fields =
           Enum.map(atts, fn att ->
             {Ecto.UUID.dump!(att.id), Crypto.aad_bound?(att.dek_version), att.path_ciphertext,
              att.path_nonce}
           end),
         {:ok, paths} <-
           Envelope.decrypt_many(dek, Crypto.aad_prefix(:attachments, :path), fields) do
      Enum.zip_with(atts, paths, fn att, path -> extra.(att, metadata(%{att | path: path})) end)
    else
      _ -> decrypt_each(atts, user, extra)
    end
  end

  # Decrypts each row, skipping (and logging) any that fail. `extra.(att, meta)`
  # post-processes a successful metadata map (e.g. drop :deleted_at, add :id).
  defp decrypt_each(atts, user, extra) do
    Enum.flat_map(atts, fn att ->
      case decrypt_metadata(att, user) do
        {:ok, meta} ->
          [extra.(att, meta)]

        {:error, reason} ->
          require Logger

          Logger.error(
            "Skipping undecryptable attachment",
            Metadata.with_category(:error, :sync,
              attachment_id: att.id,
              reason: Metadata.safe_reason(reason)
            )
          )

          []
      end
    end)
  end

  defp unwrap_tenant({:ok, {:ok, result}}), do: {:ok, result}
  defp unwrap_tenant({:ok, {:error, _} = err}), do: err
  defp unwrap_tenant({:ok, result}), do: {:ok, result}
  defp unwrap_tenant({:error, _} = err), do: err

  # The cached vault content counts (`:note_counts`). The note_counts_changed
  # trigger evicts every node on commit; this makes the writing node coherent
  # without waiting for its NOTIFY. Engram.Cache.evict/2 waits for the commit.
  defp evict_counts(user_id), do: Engram.Cache.evict(:note_counts, user_id)
end
