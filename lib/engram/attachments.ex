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
  alias Engram.Links
  alias Engram.Logger.Metadata
  alias Engram.Notes.Enqueue
  alias Engram.Notes.PathSanitizer
  alias Engram.Repo
  alias Engram.Storage
  alias Engram.Storage.MimeWhitelist
  alias Engram.Sync.Broadcast
  alias Engram.Workers.RebindNoteLinks

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
  Upserts an attachment. Decodes base64 content, detects MIME type, computes hash.
  Returns {:ok, attachment} or {:error, reason}.
  """
  def upsert_attachment(user, vault, attrs) do
    path = (attrs["path"] || attrs[:path]) |> PathSanitizer.sanitize()
    content_b64 = attrs["content_base64"] || attrs[:content_base64]
    mtime = attrs["mtime"] || attrs[:mtime]
    explicit_mime = attrs["mime_type"] || attrs[:mime_type]

    with {:ok, plaintext} <- decode_base64(content_b64),
         # Security boundary: enforced HERE, not (only) in the controller —
         # MCP tools, Oban jobs, and console callers must hit the same gate.
         :ok <- MimeWhitelist.check(explicit_mime || MimeWhitelist.detect_mime(path), path),
         :ok <- validate_size(plaintext, user),
         {:ok, user} <- Crypto.ensure_user_dek(user),
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

      with :ok <- validate_storage_cap(user, existing0, byte_size(plaintext)),
           {:ok, key, attrs0, ciphertext} <-
             prepare_upload(
               user,
               vault,
               att_id0,
               path,
               {path_hmac, basename_hmac},
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
                           {path_hmac, basename_hmac},
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
              # without a second decrypt round-trip. `is_nil(existing)`
              # (captured under the same lock that decided insert-vs-update
              # in write_row/4) tells the caller below whether this was a
              # CREATE, for the #591 create-only rebind hook.
              {:ok, {%{att | path: path}, is_nil(existing)}}
            end
            |> case do
              {:ok, pair} -> pair
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
        with {:ok, {%Attachment{} = att, created?}} <- result do
          broadcast_attachment(user.id, vault.id, "upsert", path, att)

          # #591 — a brand-new attachment may be the exact target a dangling
          # embed/link (or an existing binding losing the shortest-path
          # tiebreak) has been waiting on. Only on CREATE: an update never
          # changes the basename other edges could bind to (moves go
          # through move_attachment/4, which carries its own rebind hook).
          if created? do
            _ =
              Enqueue.enqueue(
                RebindNoteLinks.new_for(
                  user.id,
                  vault.id,
                  Links.basename_hmac(user, Links.basename_key(path))
                ),
                "rebind_note_links"
              )
          end
        end

        case result do
          {:ok, {att, _created?}} -> {:ok, att}
          {:error, _} = err -> err
        end
      end
    end
  end

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
  # ponytail: trusts the DB row, not S3. If an object vanished from the bucket
  # behind a live row, re-sending identical bytes no longer repairs it —
  # delete-then-reupload does (verified: `fetch_existing` is `scoped_live`, so
  # a tombstoned row is invisible here and resurrection takes the full path).
  # Upgrade path if that ever bites: HEAD the storage key before returning.
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
         true <- stored == Crypto.hmac_content_hash(content_key, plaintext) do
      # `path` is virtual (Phase B.3); splice it on so this return is
      # shape-identical to the write path's.
      {:ok, %{att | path: path}}
    else
      _ -> :changed
    end
  end

  defp identical_or_changed(_user, _existing, _plaintext, _path, _explicit_mime), do: :changed

  defp fetch_existing(user, vault_id, path_hmac) do
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
      # are keyed by the immutable attachment UUID (`Storage.object_key/3`);
      # nothing reconstructs a key from a path any more, and the builder that
      # could is deleted.
      {:ok, %Attachment{storage_key: nil} = att} ->
        require Logger

        Logger.error(
          "Attachment row has no storage_key",
          Metadata.with_category(:error, :sync, attachment_id: att.id)
        )

        {:error, {:storage, :blob_missing}}

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
            seq = Engram.Vaults.next_seq!(vault.id)

            {count, rows} =
              from(a in scoped_live(user, vault),
                where: a.path_hmac == ^path_hmac,
                select: {a.id, a.storage_key, a.basename_hmac}
              )
              |> Repo.update_all(set: [deleted_at: now, updated_at: now, seq: seq])

            {count, List.first(rows)}
          end)
          |> unwrap_tenant()

        # Best-effort blob cleanup — row is already soft-deleted so safe to retry.
        # `edge_hook` carries {attachment_id, basename_hmac} for the #591
        # edge-flip + sibling-rebind below, nil when no live row matched.
        {deleted?, edge_hook} =
          case result do
            {:ok, {count, {id, key, basename_hmac}}} when count > 0 ->
              if is_binary(key), do: delete_external(key)
              {true, {id, basename_hmac}}

            # {count, nil}: count is always 0 here — the select always returns
            # the {id, storage_key, basename_hmac} 3-tuple (storage_key may
            # itself be nil for a legacy row, but that still matches the
            # first branch above and unpacks fine). List.first(rows) is only
            # nil when rows == [], i.e. no live row matched path_hmac
            # (absent or already-deleted path).
            {:ok, {count, _}} ->
              {count > 0, nil}

            {:error, reason} ->
              require Logger

              Logger.warning(
                "delete_attachment: tenant lookup failed",
                Metadata.with_category(:warning, :sync, reason: Metadata.safe_reason(reason))
              )

              {false, nil}
          end

        # #591 — the attachment is gone: flip any incoming edges back to
        # dangling, then chain a rebind for its OWN basename so a same-
        # basename sibling elsewhere can inherit the edges it's vacating
        # (same pattern as DeleteNoteIndex's chained rebind for notes).
        _ =
          if edge_hook do
            {attachment_id, basename_hmac} = edge_hook
            :ok = Links.on_attachment_soft_deleted(user.id, attachment_id)

            Enqueue.enqueue(
              RebindNoteLinks.new_for(user.id, vault.id, basename_hmac),
              "rebind_note_links"
            )
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

            Broadcast.emit("sync:#{user.id}:#{vault.id}", "note_changed", payload)
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
      old_basename_hmac = Crypto.hmac_field(filter_key, Links.basename_key(old_path))
      new_basename_hmac = Crypto.hmac_field(filter_key, Links.basename_key(new_path))

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
                    basename_hmac: new_basename_hmac,
                    updated_at: now,
                    seq: seq
                  ]
                )

              # Insert the old-path tombstone (fresh uuid, path encrypted under
              # ITS OWN id-AAD). Sole purpose: surface {old_path, deleted: true}
              # in the change feed so clients trash the old path.
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

              %{
                live
                | path: new_path,
                  path_ciphertext: path_ct,
                  path_nonce: path_n,
                  path_hmac: new_hmac,
                  basename_hmac: new_basename_hmac,
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
          _ =
            if old_path != new_path do
              broadcast_attachment(user.id, vault.id, "delete", old_path, att)
              broadcast_attachment(user.id, vault.id, "upsert", new_path, att)

              # #591 — re-resolve edges for BOTH basenames: the new name may
              # bind danglers waiting on it, and the old name's remaining
              # candidates (a same-basename sibling elsewhere) may need to
              # inherit the edges this attachment is vacating. Both hmacs are
              # already computed above (needed for the repoint/tombstone
              # writes), so no extra derivation here.
              _ =
                Enqueue.enqueue(
                  RebindNoteLinks.new_for(user.id, vault.id, new_basename_hmac),
                  "rebind_note_links"
                )

              _ =
                if new_basename_hmac != old_basename_hmac do
                  Enqueue.enqueue(
                    RebindNoteLinks.new_for(user.id, vault.id, old_basename_hmac),
                    "rebind_note_links"
                  )
                end

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
  # content_hash + content_nonce carried from the live row (the changeset
  # requires content_nonce; the value is irrelevant — the row is deleted and
  # never decrypted). Path encrypted under the tombstone's OWN id-AAD so reads
  # of the (never-served) row stay AAD-consistent.
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

    Attachment.changeset(%Attachment{id: tomb_id}, %{
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
  seq"): `batch_delete/3` allocates a contiguous per-row seq block (each row
  gets its OWN seq) rather than a single batch-wide `seq`. Per-row seq is SAFE
  for deletes — the soft-deleted row itself is the change signal, so the #614
  same-seq cursor-skip concern (a moved row + its same-seq tombstone) simply does
  not arise (delete has no tombstone). Cross-table + cross-item atomicity is
  provided by the `Engram.Folders` coordinator's `atomic/1` wrapper, so a
  mid-loop failure still rolls the whole op back. Reusing `batch_delete/3` keeps
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
  Soft-deletes the paths produced by `scan_folder_paths/3`. Returns the count.
  """
  # No error branch: `batch_delete/3` is hard-matched below, so this either
  # returns a count or raises.
  @spec delete_scanned_paths(map(), map(), [String.t()]) :: {:ok, non_neg_integer()}
  def delete_scanned_paths(user, vault, paths) do
    # The @max_batch_entries cap on batch_delete/3 is a REQUEST-boundary
    # guard; this folder cascade is server-internal, so chunk under the
    # cap instead of crashing on a >500-attachment folder.
    deleted =
      paths
      |> Enum.chunk_every(@max_batch_entries)
      |> Enum.reduce(0, fn chunk, acc ->
        {:ok, %{deleted: n}} = batch_delete(user, vault, chunk)
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
  post-commit side effects — one batched blob delete plus the same per-path
  `note_changed` delete broadcast `do_delete_attachment/4` emits (payload
  shape identical; batch calls carry no origin device, same as before).

  Capped at 500 paths per batch (`{:error, :batch_too_large}` above that).
  """
  @spec batch_delete(map(), map(), [String.t()]) ::
          {:ok, %{deleted: non_neg_integer()}} | {:error, :batch_too_large}
  def batch_delete(_user, _vault, []), do: {:ok, %{deleted: 0}}

  def batch_delete(_user, _vault, paths)
      when is_list(paths) and length(paths) > @max_batch_entries,
      do: {:error, :batch_too_large}

  def batch_delete(user, vault, paths) when is_list(paths) do
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
        {:ok, {deleted_ids, deleted_hmacs, basename_hmacs, storage_keys}} =
          batch_soft_delete_rows(user, vault, Map.values(hmac_by_path))

        # Post-commit side effects — batched blob cleanup (best-effort,
        # rows are already soft-deleted so a failure only leaks a zombie
        # blob, exactly like the single-delete path), then one broadcast
        # per deleted path in input order.
        delete_external_many(storage_keys)

        # #591 — same edge-flip + sibling-rebind as the single-delete path,
        # batched: one Links.on_attachments_soft_deleted/2 UPDATE for the
        # whole batch, one rebind enqueue per unique basename in the batch.
        :ok = Links.on_attachments_soft_deleted(user.id, deleted_ids)

        Enum.each(basename_hmacs, fn hmac ->
          _ =
            Enqueue.enqueue(
              RebindNoteLinks.new_for(user.id, vault.id, hmac),
              "rebind_note_links"
            )
        end)

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
  # `{:ok, {deleted_ids, deleted_path_hmacs, basename_hmacs, storage_keys}}`
  # for the actually-deleted rows — `deleted_ids` + `basename_hmacs` feed the
  # #591 edge-flip + sibling-rebind in `batch_delete/3`.
  defp batch_soft_delete_rows(_user, _vault, []), do: {:ok, {[], [], [], []}}

  defp batch_soft_delete_rows(user, vault, hmacs) do
    now = DateTime.utc_now(:second)

    Repo.with_tenant(user.id, fn ->
      rows =
        from(a in scoped_live(user, vault),
          where: a.path_hmac in ^hmacs,
          order_by: a.id,
          select: {a.id, a.path_hmac, a.storage_key}
        )
        |> Repo.all()

      if rows == [] do
        {[], [], [], []}
      else
        n = length(rows)

        # Contiguous block of N seqs in ONE statement — mirrors next_seq!/1's
        # raw-SQL idiom (the returned value is the LAST seq of the block).
        %{rows: [[last_seq]]} =
          Repo.query!(
            "UPDATE vaults SET change_seq = change_seq + $2 WHERE id = $1 RETURNING change_seq",
            [Ecto.UUID.dump!(vault.id), n]
          )

        id_seqs =
          rows
          |> Enum.with_index(last_seq - n + 1)
          |> Enum.map(fn {{id, _hmac, _key}, seq} -> {id, seq} end)

        # One UPDATE for all rows. `deleted_at IS NULL` re-guard: a row a
        # concurrent transaction deleted between our SELECT and this UPDATE is
        # skipped (its allocated seq goes unused — gaps are fine, the feed
        # only needs monotonic-unique). RETURNING tells us which rows this
        # statement actually transitioned so the count + broadcasts stay
        # truthful. Runs under the with_tenant RLS role like every other raw
        # statement in this transaction.
        values_sql =
          id_seqs
          |> Enum.with_index()
          |> Enum.map_join(", ", fn {_pair, i} ->
            "($#{i * 2 + 2}::uuid, $#{i * 2 + 3}::bigint)"
          end)

        params = [
          DateTime.to_naive(now)
          | Enum.flat_map(id_seqs, fn {id, seq} -> [Ecto.UUID.dump!(id), seq] end)
        ]

        %{rows: returned} =
          Repo.query!(
            """
            UPDATE attachments AS a
            SET deleted_at = $1, updated_at = $1, seq = v.seq
            FROM (VALUES #{values_sql}) AS v(id, seq)
            WHERE a.id = v.id AND a.deleted_at IS NULL
            RETURNING a.id, a.path_hmac, a.basename_hmac, a.storage_key
            """,
            params
          )

        # `a.id` comes back as raw 16-byte postgres uuid bytes via the
        # low-level query (unlike the Ecto-typed `rows` select above) —
        # load!/1 converts it back to the normal dashed string form other
        # callers (Links.on_attachment_soft_deleted/2) expect.
        deleted_ids = for [id, _hmac, _bn_hmac, _key] <- returned, do: Ecto.UUID.load!(id)
        deleted_hmacs = returned |> Enum.map(fn [_id, hmac, _bn, _key] -> hmac end) |> Enum.uniq()
        basename_hmacs = returned |> Enum.map(fn [_id, _hmac, bn, _key] -> bn end) |> Enum.uniq()
        storage_keys = for [_id, _hmac, _bn, key] <- returned, is_binary(key), do: key
        {deleted_ids, deleted_hmacs, basename_hmacs, storage_keys}
      end
    end)
    |> unwrap_tenant()
  end

  # Batched counterpart of delete_external/1 — same best-effort contract.
  defp delete_external_many([]), do: :ok

  defp delete_external_many(storage_keys) do
    case Storage.adapter().delete_many(storage_keys) do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning(
          "Failed to batch-delete blobs (rows already soft-deleted)",
          Metadata.with_category(:warning, :sync,
            key_count: length(storage_keys),
            reason: Metadata.safe_reason(reason)
          )
        )

        :ok
    end
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

    _ = Broadcast.emit("sync:#{user_id}:#{vault_id}", "note_changed", payload)
    :ok
  end

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
      decrypt_each(atts, user, fn att, meta ->
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

  # -- Private helpers --

  # Pricing v2 §G — per-plan max_file_bytes via `Engram.Billing`. When
  # limits aren't enforced (self-host without Paddle), `effective_limit`
  # returns `:unlimited` and uploads are unbounded — operator's call.
  defp validate_size(binary, user) do
    case Billing.effective_limit(user, :max_file_bytes) do
      # A NEGATIVE limit is the "unlimited" sentinel (check_limit/3,
      # normalize_capability/2, Billing.plan_state/1), never a real ceiling.
      # Without this clause an operator lifting the cap with -1 rejects EVERY
      # upload as {:too_large, -1} — and since the client is told the limit is
      # nil, its own pre-gate passes and the rejection arrives unexplained.
      n when is_integer(n) and n < 0 -> :ok
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
         att_id,
         path,
         {path_hmac, basename_hmac},
         plaintext,
         mtime,
         explicit_mime
       ) do
    mime = explicit_mime || MimeWhitelist.detect_mime(path)
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
        path_hmac: path_hmac,
        basename_hmac: basename_hmac
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
end
