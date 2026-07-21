defmodule Engram.Attachments do
  @moduledoc """
  Attachments context — CRUD for binary file attachments.
  All operations are tenant-scoped via Repo.with_tenant/2.

  Binary storage goes to the configured S3-compatible adapter
  (MinIO locally, Tigris in prod). Ciphertext only — every row
  is `encryption_version = 1` since A.5 (PR #62, 2026-05-02).
  """

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.Billing
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Logger.Metadata
  alias Engram.Notes.PathSanitizer
  alias Engram.Repo
  alias Engram.Storage
  alias Engram.Storage.MimeWhitelist

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
         :ok <- validate_size(plaintext, user),
         {:ok, user} <- Crypto.ensure_user_dek(user),
         {:ok, filter_key} <- Crypto.dek_filter_key(user) do
      path_hmac = Crypto.hmac_field(filter_key, path)

      # Pre-lock window: probable-id read, cap check, encrypt, and the S3
      # PUT all run WITHOUT holding a pool transaction or the advisory
      # lock — a slow multi-MB upload must not pin a DB connection
      # (POOL_SIZE defaults to 10; a handful of concurrent uploads used to
      # starve the whole API). The locked transaction below re-checks
      # `existing` and repairs the rare race.
      existing0 = fetch_existing(user, vault.id, path_hmac)

      att_id0 =
        case existing0 do
          nil -> Ecto.UUID.generate()
          %Attachment{id: id} -> id
        end

      with :ok <- validate_storage_cap(user, existing0, byte_size(plaintext)),
           {:ok, key, attrs0, ciphertext} <-
             prepare_upload(
               user,
               vault,
               att_id0,
               path,
               path_hmac,
               plaintext,
               mtime,
               explicit_mime
             ),
           :ok <- store_external(key, ciphertext, attrs0.mime_type) do
        # T3-audit H1 — concurrent upserts to the same path can race: each
        # encrypts the blob with AAD bound to its own att_id, then PUTs to
        # the same S3 key (last writer wins on the blob). The surviving DB
        # row's id must match the AAD baked into the surviving blob, so the
        # row write is serialized per (user, path) via a transaction-scoped
        # advisory lock; if the locked re-read reveals a different winning
        # id, we re-encrypt + re-PUT under the lock (rare race path only).
        # The lock auto-releases on commit/rollback.
        result =
          Repo.transaction(fn ->
            :ok = acquire_path_lock(user.id, path_hmac)

            existing = fetch_existing(user, vault.id, path_hmac)

            rebind =
              case existing do
                %Attachment{id: id} when id != att_id0 ->
                  with {:ok, rebind_key, attrs1, ciphertext1} <-
                         prepare_upload(
                           user,
                           vault,
                           id,
                           path,
                           path_hmac,
                           plaintext,
                           mtime,
                           explicit_mime
                         ),
                       :ok <- store_external(rebind_key, ciphertext1, attrs1.mime_type) do
                    {:ok, attrs1}
                  end

                _ ->
                  {:ok, attrs0}
              end

            with {:ok, changeset_attrs} <- rebind,
                 {:ok, att} <- write_row(user, existing, att_id0, changeset_attrs) do
              # Phase B.3: path is virtual — splice the plaintext we already
              # have onto the returned struct so callers can read att.path
              # without a second decrypt round-trip.
              {:ok, %{att | path: path}}
            end
            |> case do
              {:ok, att} -> att
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

        # Real-time notification (Engram#942) — create/upload previously had NO
        # live signal at all (only delete and move broadcast), so peers only
        # ever saw a new/changed attachment via the next manual pull. Mirrors
        # the "upsert" leg of move_attachment/4's broadcast_attachment/5 below
        # — the plugin's WebSocket handler already fetches + materializes any
        # attachment "upsert" event (it's the same code path move's new-path
        # leg drives), so no plugin change is needed.
        with {:ok, %Attachment{} = att} <- result do
          broadcast_attachment(user.id, vault.id, "upsert", path, att)
        end

        result
      end
    end
  end

  defp fetch_existing(user, vault_id, path_hmac) do
    Repo.with_tenant(user.id, fn ->
      Repo.one(
        from(a in Attachment,
          where:
            a.path_hmac == ^path_hmac and a.user_id == ^user.id and
              a.vault_id == ^vault_id and is_nil(a.deleted_at)
        )
      )
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

            Logger.error(
              "Attachment blob missing for live row",
              Metadata.with_category(:error, :sync,
                attachment_id: att.id,
                storage_key: key
              )
            )

            {:error, {:storage, :blob_missing}}

          {:error, reason} ->
            require Logger
            reason_str = inspect(reason)

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
  Soft-deletes an attachment. Idempotent — returns :ok even if already deleted or nonexistent.

  Ordering: soft-delete the DB row first (reversible), then delete the blob (permanent).
  If the blob delete fails, the row stays deleted and we log a warning — a zombie blob
  wastes storage but doesn't cause data loss, unlike the reverse (ghost row pointing to nothing).
  """
  def delete_attachment(user, vault, path, opts \\ []) do
    _ = do_delete_attachment(fresh_user(user), vault, path, opts)
    :ok
  end

  # Soft-deletes one attachment and returns whether a live row actually
  # transitioned to deleted (`false` for an absent/already-deleted path).
  # Broadcasts + best-effort blob cleanup happen here so both the single-delete
  # API and `batch_delete/3` share one implementation and count truthfully.
  # opts[:origin_device_id] is stamped into the delete broadcast (#970) so the
  # originating device can drop its own fanout echo.
  defp do_delete_attachment(user, vault, path, opts \\ []) do
    path = PathSanitizer.sanitize(path)
    now = DateTime.utc_now(:second)

    case Crypto.dek_filter_key(user) do
      {:ok, filter_key} ->
        path_hmac = Crypto.hmac_field(filter_key, path)

        result =
          Repo.with_tenant(user.id, fn ->
            seq = Engram.Vaults.next_seq!(vault.id)

            {count, keys} =
              from(a in Attachment,
                where:
                  a.path_hmac == ^path_hmac and a.user_id == ^user.id and
                    a.vault_id == ^vault.id and is_nil(a.deleted_at),
                select: a.storage_key
              )
              |> Repo.update_all(set: [deleted_at: now, updated_at: now, seq: seq])

            {count, List.first(keys)}
          end)
          |> unwrap_tenant()

        # Best-effort blob cleanup — row is already soft-deleted so safe to retry.
        deleted? =
          case result do
            {:ok, {count, key}} when is_binary(key) ->
              delete_external(key)
              count > 0

            # {count, nil}: legacy row with no storage_key, or no row matched.
            {:ok, {count, _}} ->
              count > 0

            {:error, reason} ->
              require Logger

              Logger.warning(
                "delete_attachment: tenant lookup failed",
                Metadata.with_category(:warning, :sync, reason: inspect(reason))
              )

              false
          end

        # Real-time notification — only when a live row actually transitioned to
        # deleted (idempotent no-op deletes of an absent/already-deleted path
        # don't emit a spurious delete). path/vault are known; mime/size/mtime
        # are gone post-delete, so only the discriminators the plugin needs to
        # trash are sent.
        _ =
          if deleted? do
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

            Engram.Sync.Broadcast.emit("sync:#{user.id}:#{vault.id}", "note_changed", payload)
          end

        deleted?

      {:error, :no_dek} ->
        # No DEK = no attachments to delete; mirror get_attachment's defensive empty.
        false
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
            reason: inspect(reason)
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
          {:ok, Attachment.t()} | {:error, :conflict | :not_found | term()}
  def move_attachment(user, vault, old_path, new_path) do
    old_path = PathSanitizer.sanitize(old_path)
    new_path = PathSanitizer.sanitize(new_path)
    user = fresh_user(user)
    now = DateTime.utc_now(:second)

    with {:ok, user} <- Crypto.ensure_user_dek(user),
         {:ok, dek} <- Crypto.get_dek(user),
         {:ok, filter_key} <- Crypto.dek_filter_key(user) do
      old_hmac = Crypto.hmac_field(filter_key, old_path)
      new_hmac = Crypto.hmac_field(filter_key, new_path)

      Repo.transaction(fn ->
        Repo.with_tenant(user.id, fn ->
          live = Repo.one(live_by_hmac_query(user, vault, old_hmac))

          cond do
            is_nil(live) ->
              Repo.rollback(:not_found)

            old_path == new_path ->
              case Crypto.maybe_decrypt_attachment_fields(live, user) do
                {:ok, att} -> att
                {:error, reason} -> Repo.rollback(reason)
              end

            Repo.one(live_by_hmac_query(user, vault, new_hmac)) ->
              Repo.rollback(:conflict)

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
                  set: [
                    path_ciphertext: path_ct,
                    path_nonce: path_n,
                    path_hmac: new_hmac,
                    updated_at: now,
                    seq: seq
                  ]
                )

              # Insert the old-path tombstone (fresh uuid, path encrypted under
              # ITS OWN id-AAD). Sole purpose: surface {old_path, deleted: true}
              # in the change feed so clients trash the old path.
              Repo.insert!(
                tombstone_changeset(user, vault, dek, old_path, old_hmac, live, seq, now)
              )

              %{
                live
                | path: new_path,
                  path_ciphertext: path_ct,
                  path_nonce: path_n,
                  path_hmac: new_hmac,
                  updated_at: now,
                  seq: seq
              }
          end
        end)
        |> unwrap_tenant()
        |> case do
          {:ok, att} -> att
          # No current cond branch returns {:error,_} without rolling back itself;
          # this guards a future branch that returns an error tuple directly.
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, %Attachment{} = att} ->
          if old_path != new_path do
            broadcast_attachment(user.id, vault.id, "delete", old_path, att)
            broadcast_attachment(user.id, vault.id, "upsert", new_path, att)
          end

          {:ok, att}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp live_by_hmac_query(user, vault, hmac) do
    from(a in Attachment,
      where:
        a.path_hmac == ^hmac and a.user_id == ^user.id and
          a.vault_id == ^vault.id and is_nil(a.deleted_at)
    )
  end

  # Soft-deleted full-row insert at the vacated path. storage_key=nil (no blob),
  # content_hash + content_nonce carried from the live row (the changeset
  # requires content_nonce; the value is irrelevant — the row is deleted and
  # never decrypted). Path encrypted under the tombstone's OWN id-AAD so reads
  # of the (never-served) row stay AAD-consistent.
  defp tombstone_changeset(user, vault, dek, old_path, old_hmac, live, seq, now) do
    tomb_id = Ecto.UUID.generate()
    path_aad = Crypto.aad_for_row(:attachments, :path, tomb_id)
    {path_ct, path_n} = Envelope.encrypt(old_path, dek, path_aad)

    Attachment.changeset(%Attachment{id: tomb_id}, %{
      path_ciphertext: path_ct,
      path_nonce: path_n,
      path_hmac: old_hmac,
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
      encryption_version: 1,
      dek_version: Crypto.row_version_aad_bound(),
      content_nonce: live.content_nonce
    })
  end

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
    pairs =
      Enum.map(paths, fn old_path ->
        base = Path.basename(old_path)
        new_path = if target_folder == "", do: base, else: Path.join(target_folder, base)
        {old_path, new_path}
      end)

    # This surface tags conflict/not_found with the offending path so the REST
    # controller can name it in the 409/404 body (`{:conflict, path}`).
    case move_pairs(user, vault, pairs, &tag_move_error/2) do
      {:ok, count} -> {:ok, %{moved: count}}
      {:error, _} = err -> err
    end
  end

  # Shared move-loop for every "relocate these [{old, new}] pairs atomically"
  # caller (`batch_move/4` + the folder-rename cascade). One `Repo.transaction`
  # wraps `reduce_while` over `move_attachment/4` (which carries the #614 per-item
  # repoint+tombstone-share-one-seq discipline); any item error halts and rolls
  # the WHOLE batch back. `on_error.(reason, old_path)` shapes the rollback value
  # so each surface keeps its own contract (bare `:conflict` for folder rename,
  # `{:conflict, path}` for `batch_move`). Returns `{:ok, count}` | `{:error, _}`.
  defp move_pairs(_user, _vault, [], _on_error), do: {:ok, 0}

  defp move_pairs(user, vault, pairs, on_error) do
    Repo.transaction(fn ->
      Enum.reduce_while(pairs, 0, fn {old_path, new_path}, count ->
        case move_attachment(user, vault, old_path, new_path) do
          {:ok, _} -> {:cont, count + 1}
          {:error, reason} -> {:halt, {:rollback, on_error.(reason, old_path)}}
        end
      end)
      |> case do
        {:rollback, reason} -> Repo.rollback(reason)
        count -> count
      end
    end)
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
  @spec rename_folder(map(), map(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def rename_folder(user, vault, old_folder, new_folder) do
    old_folder = String.trim_trailing(old_folder, "/")
    new_folder = String.trim_trailing(new_folder, "/")
    prefix = old_folder <> "/"
    old_len = String.length(old_folder)

    case list_attachments(user, vault) do
      {:ok, metas} ->
        pairs =
          metas
          |> Enum.filter(&String.starts_with?(&1.path, prefix))
          |> Enum.map(fn %{path: old_path} ->
            {old_path, new_folder <> String.slice(old_path, old_len..-1//1)}
          end)

        move_folder_pairs(user, vault, pairs)

      {:error, reason} ->
        {:error, reason}
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
  `move_pairs/4` loop passes the raw reason through unchanged. Returns
  `{:ok, count}` (0 = no pairs, idempotent).
  """
  @spec move_folder_pairs(map(), map(), [{String.t(), String.t()}]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def move_folder_pairs(user, vault, pairs) do
    move_pairs(user, vault, pairs, fn reason, _old_path -> reason end)
  end

  @doc """
  Cascades a folder delete across attachments: soft-deletes every live attachment
  whose path sits under `folder` (incl. nested). Reuses `batch_delete/3` so each
  delete broadcasts + runs best-effort blob cleanup. Returns `{:ok, count}` (0 =
  no attachments, idempotent).

  Seq note (DRY-by-design, diverges from a literal "one transaction under one
  seq"): `batch_delete/3` → `do_delete_attachment` allocates a fresh per-item
  `seq` per path rather than a single batch-wide `seq`. Per-item seq is SAFE for
  deletes — the soft-deleted row itself is the change signal, so the #614
  same-seq cursor-skip concern (a moved row + its same-seq tombstone) simply does
  not arise (delete has no tombstone). Cross-table + cross-item atomicity is
  provided by the `Engram.Folders` coordinator's `atomic/1` wrapper, so a
  mid-loop failure still rolls the whole op back. Reusing `batch_delete/3` keeps
  one delete path instead of a bespoke single-seq `update_all`.
  """
  @spec delete_folder(map(), map(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete_folder(user, vault, folder) do
    prefix = String.trim_trailing(folder, "/") <> "/"

    case list_attachments(user, vault) do
      {:ok, metas} ->
        paths = metas |> Enum.map(& &1.path) |> Enum.filter(&String.starts_with?(&1, prefix))
        {:ok, %{deleted: n}} = batch_delete(user, vault, paths)
        {:ok, n}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Soft-deletes each attachment by path. Idempotent. `:deleted` counts paths that
  actually held a live row (absent/already-deleted paths don't count).
  """
  @spec batch_delete(map(), map(), [String.t()]) :: {:ok, %{deleted: non_neg_integer()}}
  def batch_delete(_user, _vault, []), do: {:ok, %{deleted: 0}}

  def batch_delete(user, vault, paths) when is_list(paths) do
    user = fresh_user(user)
    deleted = Enum.count(paths, fn p -> do_delete_attachment(user, vault, p) end)
    {:ok, %{deleted: deleted}}
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
      "mtime" => att.mtime
    }

    _ = Engram.Sync.Broadcast.emit("sync:#{user_id}:#{vault_id}", "note_changed", payload)
    :ok
  end

  @doc """
  Lists non-deleted attachment metadata for a vault (no content).
  """
  def list_attachments(user, vault) do
    user = fresh_user(user)

    Repo.with_tenant(user.id, fn ->
      from(a in Attachment,
        where: a.user_id == ^user.id and a.vault_id == ^vault.id and is_nil(a.deleted_at),
        order_by: [asc: a.updated_at]
      )
      |> Repo.all()
    end)
    |> unwrap_tenant()
    |> case do
      {:ok, atts} ->
        {:ok,
         decrypt_each(atts, user, fn att, meta ->
           meta |> Map.delete(:deleted_at) |> Map.put(:id, att.id)
         end)}

      err ->
        err
    end
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
        {:ok, decrypt_each(atts, user, fn _att, meta -> meta end)}

      err ->
        err
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
      from(a in Attachment,
        where: a.user_id == ^user.id and a.vault_id == ^vault.id and not is_nil(a.seq),
        order_by: [asc: a.seq, asc: a.id],
        limit: ^(limit + 1)
      )

    base =
      if after_id do
        from(a in base, where: a.seq > ^after_seq or (a.seq == ^after_seq and a.id > ^after_id))
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

  # Pricing v2 §G — per-plan max_file_bytes via `Engram.Billing`. When
  # limits aren't enforced (self-host without Paddle), `effective_limit`
  # returns `:unlimited` and uploads are unbounded — operator's call.
  defp validate_size(binary, user) do
    case Billing.effective_limit(user, :max_file_bytes) do
      n when is_integer(n) and byte_size(binary) > n -> {:error, {:too_large, n}}
      _ -> :ok
    end
  end

  # Pricing v2 §G — per-plan attachment_bytes_cap (lifetime quota).
  # Compute the net new total: current sum minus the existing row's
  # size (if upserting) plus the new payload size. Sum is scoped to
  # non-deleted rows via storage_usage/1. Runs inside the per-path
  # advisory lock for consistency with the writer's view of `existing`.
  defp validate_storage_cap(user, existing, new_size) do
    case Billing.effective_limit(user, :attachment_bytes_cap) do
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

  defp prepare_upload(user, vault, att_id, path, path_hmac, plaintext, mtime, explicit_mime) do
    mime = explicit_mime || MimeWhitelist.detect_mime(path)
    # was: key = Storage.key(user.id, vault.id, path)
    key = Storage.object_key(user.id, vault.id, att_id)

    with {:ok, dek} <- Crypto.get_dek(user),
         {:ok, content_key} <- Crypto.dek_content_hash_key(user) do
      hash = Crypto.hmac_content_hash(content_key, plaintext)
      content_aad = Crypto.aad_for_row(:attachments, :content, att_id)
      path_aad = Crypto.aad_for_row(:attachments, :path, att_id)
      {ciphertext, nonce} = Envelope.encrypt(plaintext, dek, content_aad)
      {path_ct, path_n} = Envelope.encrypt(path, dek, path_aad)

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
        dek_version: Crypto.row_version_aad_bound(),
        content_nonce: nonce,
        path_ciphertext: path_ct,
        path_nonce: path_n,
        path_hmac: path_hmac
      }

      {:ok, key, attrs, ciphertext}
    end
  end

  defp store_external(key, binary, mime) do
    case Storage.adapter().put(key, binary, content_type: mime) do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger
        reason_str = inspect(reason)

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
  defp fresh_user(%Engram.Accounts.User{encrypted_dek: nil} = user), do: Repo.reload!(user)
  defp fresh_user(%Engram.Accounts.User{} = user), do: user

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
      {:ok, decrypted} ->
        {:ok,
         %{
           path: decrypted.path,
           mime_type: decrypted.mime_type,
           size_bytes: decrypted.size_bytes,
           mtime: decrypted.mtime,
           updated_at: decrypted.updated_at,
           deleted_at: decrypted.deleted_at
         }}

      {:error, reason} ->
        {:error, reason}
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
              reason: inspect(reason)
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
end
