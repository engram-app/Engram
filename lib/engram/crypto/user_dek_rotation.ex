defmodule Engram.Crypto.UserDekRotation do
  @moduledoc """
  T3.7 — per-user DEK rotation orchestrator. Generates a new DEK for the
  target user, rewraps every ciphertext column on every owned row
  (notes / vaults / attachments / note_links / Qdrant payloads) under the
  new key, then atomically flips `users.encrypted_dek`.

  The user is locked (read + write) for the duration via
  `Engram.Crypto.RotationLock`; clients receive HTTP 503 with
  `Retry-After: 60` until the rotation completes.

  ## Idempotence

  Unlike `MasterRotation` (which is idempotent within a master key generation),
  this orchestrator generates a **fresh DEK on every call**. There is no
  "already at target" short-circuit. Operators should not re-run unnecessarily.
  The rotation lock prevents concurrent calls; a stale lock (> 10 min) is taken
  over automatically.

  ## Per-row dek_version semantics

  Per-row `dek_version` is the **AAD schema version** (1 = legacy empty-AAD,
  2 = AAD-bound per T3.6). It is NOT a DEK generation counter. The sweep does
  not filter rows by `dek_version < target`; instead it iterates ALL rows for
  the user and uses decrypt-as-discriminator to determine whether each row is
  under the old or new DEK (the latter meaning a prior crashed run already
  re-encrypted it).

  See `docs/encryption-tier-3-audit.md` § Phase T3.7.
  """

  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts.User
  alias Engram.Attachments.SegmentedCipher
  alias Engram.Attachments.Upload
  alias Engram.Auth.SessionInvalidator
  alias Engram.Crypto
  alias Engram.Crypto.{DekCache, Envelope, MigrationRunner, RotationLock, TenantSweep}
  alias Engram.Crypto.KeyProvider.Resolver
  alias Engram.Indexing
  alias Engram.Logger.Metadata
  alias Engram.Notes.CrdtUpdateLog
  alias Engram.Notes.FieldCatalog
  alias Engram.Notes.FlatFields
  alias Engram.Notes.FrontmatterKeys
  alias Engram.Repo
  alias Engram.Vector.Qdrant
  alias Engram.Workers.{EmbedNote, ReconcileNotePayloads, RotationTextGuard}

  require Logger

  @batch_size 200

  @type rotate_result :: :ok | {:error, term()}

  @spec rotate_user(String.t() | User.t()) :: rotate_result()
  def rotate_user(user_or_id) do
    user_id =
      case user_or_id do
        %User{id: id} -> id
        id when is_binary(id) -> id
      end

    # B5: started_at captured inside the wrapper so the telemetry emission
    # below is ALWAYS reached — even when do_rotate raises or exits.
    started_at = System.monotonic_time()

    try do
      result = do_rotate(user_id)
      emit_telemetry(user_id, result, MigrationRunner.duration_us_since(started_at))
      result
    rescue
      e ->
        emit_telemetry(user_id, {:error, :crashed}, MigrationRunner.duration_us_since(started_at))
        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        emit_telemetry(user_id, {:error, :crashed}, MigrationRunner.duration_us_since(started_at))
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp do_rotate(user_id) do
    with {:ok, user} <- load_user(user_id),
         {:ok, _locked_at} <- RotationLock.acquire(user_id) do
      # T3.7 (#1092): with the lock held, no new crdt: socket can join
      # (RotationGate on join). Drain the ones already open so live WS clients
      # stop writing/encrypting mid-rotation — they reconnect and hit the join
      # gate. Same force-disconnect the entitlement/auth paths already use.
      SessionInvalidator.disconnect_user(user_id)

      new_dek_version = (user.dek_version || 1) + 1

      # B5: full try/rescue/catch so that :exit (pool exhaustion, SIGTERM) and
      # :throw bypass neither the structured log nor the lock-retention comment.
      try do
        run_phases(user, new_dek_version)
      rescue
        e ->
          Logger.error(
            "T3.7 rotate_user crashed",
            Metadata.with_category(:error, :crypto,
              user_id: user_id,
              new_dek_version: new_dek_version,
              kind: :error,
              exception_struct: e.__struct__,
              message: Metadata.safe_reason(e)
            )
          )

          # Lock intentionally NOT released — operator must investigate
          # before retry. Re-raise so caller sees the failure.
          reraise e, __STACKTRACE__
      catch
        kind, reason when kind in [:exit, :throw] ->
          Logger.error(
            "T3.7 rotate_user terminated",
            Metadata.with_category(:error, :crypto,
              user_id: user_id,
              new_dek_version: new_dek_version,
              kind: kind,
              reason: Metadata.safe_exit_reason(reason)
            )
          )

          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    else
      {:error, _} = err -> err
    end
  end

  # The sweep is now a writer of `crdt_state_ciphertext`, which trips the
  # `notes_crdt_head_invalidate` BEFORE UPDATE trigger and NULLs the cached head
  # for every synced note. Left NULL, the plugin's head-equality fast path can
  # never hit and every live-bound note re-handshakes on every manifest
  # reconcile. `BackfillCrdtHead` re-warms it and is an idempotent no-op when
  # there is nothing to do. #1341.
  #
  # Enqueued right after `sweep_notes`, NOT after `final_flip`: the trigger has
  # already fired by then, so hanging the repair off the all-phases-succeeded
  # branch would skip it in exactly the case that needs it most — a later phase
  # (attachments/S3, Qdrant) failing after every head was cleared. The worker's
  # own RotationGate snoozes it until the lock clears, so enqueuing early is safe.
  #
  # Only the head. A rotation does not trigger the state seed: the seed's
  # writes re-fire the same trigger and re-NULL the heads this job just warmed.
  # NULL-state notes are the `CrdtStateSeed` data migration's work, and notes
  # with an un-checkpointed tail are excluded there by
  # `BackfillCrdtState.seedable/0`.
  #
  # Best-effort: a failed enqueue must not fail the rotation.
  defp enqueue_crdt_head_rewarm(%User{id: user_id}) do
    Engram.Workers.BackfillCrdtHead.enqueue_user(user_id)
  rescue
    e ->
      Logger.error(
        "T3.7 crdt_head re-warm enqueue failed",
        Metadata.with_category(:error, :crypto,
          user_id: user_id,
          phase: :post_rotation_repairs,
          message: Metadata.safe_reason(e)
        )
      )

      :ok
  end

  defp load_user(user_id) do
    case Repo.one(from(u in User, where: u.id == ^user_id, select: u), skip_tenant_check: true) do
      nil -> {:error, :not_found}
      %User{} = u -> {:ok, u}
    end
  end

  defp run_phases(%User{} = user, new_dek_version) do
    user_id = user.id

    with {:ok, old_dek} <- Crypto.get_dek(user),
         provider = Resolver.provider_for(user_id),
         {:ok, new_wrapped, new_dek} <-
           provider.rotate_dek(user.encrypted_dek, %{user_id: user_id}),
         new_filter_key = Crypto.dek_filter_key_from_bytes(new_dek),
         :ok <- sweep_notes(user, old_dek, new_dek, new_filter_key, new_dek_version),
         :ok <- enqueue_crdt_head_rewarm(user),
         :ok <- sweep_vaults(user, old_dek, new_dek, new_filter_key, new_dek_version),
         :ok <- sweep_vault_index_states(user, old_dek, new_dek, new_dek_version),
         :ok <- sweep_vault_index_update_log(user, old_dek, new_dek, new_dek_version),
         :ok <- sweep_attachments(user, old_dek, new_dek, new_filter_key, new_dek_version),
         :ok <- sweep_attachment_uploads(user, old_dek, new_dek, new_filter_key, new_dek_version),
         :ok <- sweep_note_links(user, old_dek, new_dek, new_filter_key, new_dek_version),
         :ok <- sweep_chunk_texts(user, old_dek, new_dek),
         :ok <- sweep_slice_sums(user, old_dek, new_dek),
         :ok <- Engram.Indexing.VectorCache.rotate(to_string(user_id), old_dek, new_dek),
         :ok <- sweep_frontmatter_keys(user, old_dek, new_dek, new_filter_key),
         :ok <- resync_note_attrs(user, new_dek, new_filter_key),
         {:ok, guard} <- final_flip(user, new_dek_version, new_wrapped) do
      # The index is derived data, so it never fails the rotation: see
      # `post_flip_index_repairs/3`. The DB-only remap goes first, while few
      # edits can have landed; an incomplete text sweep then overrides it.
      :ok = post_flip_index_repairs(user, old_dek, new_dek)
      :ok = sweep_qdrant_after_flip(user, old_dek, new_dek, guard)
      # Finished (or requeued what it could not rewrap): the guard is moot.
      :ok = cancel_text_guard(guard)

      Logger.info(
        "T3.7 per-user DEK rotation complete",
        Metadata.with_category(:info, :crypto,
          user_id: user_id,
          new_dek_version: new_dek_version,
          phase: :rotate_complete
        )
      )

      :ok
    else
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Notes sweep
  # ---------------------------------------------------------------------------

  defp sweep_notes(%User{id: user_id}, old_dek, new_dek, new_filter_key, new_dek_version) do
    TenantSweep.each_batch(
      user_id,
      Engram.Notes.Note,
      fn batch_ids ->
        Repo.transaction(fn ->
          notes =
            from(n in Engram.Notes.Note,
              where: n.id in ^batch_ids,
              lock: "FOR UPDATE"
            )
            |> Repo.all(skip_tenant_check: true)

          rewrap_crdt_tail(batch_ids, old_dek, new_dek)

          Enum.each(notes, fn note ->
            updates = rewrap_note_columns(note, old_dek, new_dek, new_filter_key, new_dek_version)

            if updates != [] do
              case from(n in Engram.Notes.Note, where: n.id == ^note.id)
                   |> Repo.update_all(
                     [set: updates ++ [dek_version: new_dek_version]],
                     skip_tenant_check: true
                   ) do
                {1, _} ->
                  :ok

                {0, _} ->
                  Logger.error(
                    "T3.7 sweep_notes: row vanished during rotation",
                    Metadata.with_category(:error, :crypto,
                      user_id: user_id,
                      table: :notes,
                      row_id: note.id,
                      phase: :sweep_notes
                    )
                  )

                  raise "T3.7 sweep_notes: row vanished mid-rotation table=notes row_id=#{note.id}"
              end
            end
          end)
        end)
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Vaults sweep
  # ---------------------------------------------------------------------------

  defp sweep_vaults(%User{id: user_id}, old_dek, new_dek, new_filter_key, new_dek_version) do
    TenantSweep.each_batch(
      user_id,
      Engram.Vaults.Vault,
      fn batch_ids ->
        Repo.transaction(fn ->
          vaults =
            from(v in Engram.Vaults.Vault,
              where: v.id in ^batch_ids,
              lock: "FOR UPDATE"
            )
            |> Repo.all(skip_tenant_check: true)

          Enum.each(vaults, fn vault ->
            updates =
              rewrap_vault_columns(vault, old_dek, new_dek, new_filter_key, new_dek_version)

            if updates != [] do
              case from(v in Engram.Vaults.Vault, where: v.id == ^vault.id)
                   |> Repo.update_all(
                     [set: updates ++ [dek_version: new_dek_version]],
                     skip_tenant_check: true
                   ) do
                {1, _} ->
                  :ok

                {0, _} ->
                  Logger.error(
                    "T3.7 sweep_vaults: row vanished during rotation",
                    Metadata.with_category(:error, :crypto,
                      user_id: user_id,
                      table: :vaults,
                      row_id: vault.id,
                      phase: :sweep_vaults
                    )
                  )

                  raise "T3.7 sweep_vaults: row vanished mid-rotation table=vaults row_id=#{vault.id}"
              end
            end
          end)
        end)
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    )
  end

  # slug_hmac is keyed by the same filter key as name_hmac; left on the old key
  # it would stop matching and /v/:slug lookup would 404 after rotation. The
  # slug is derived from the name (no ciphertext of its own), so it is
  # re-hashed from the plaintext name the rewrap decrypts.
  defp rewrap_vault_columns(vault, old_dek, new_dek, new_filter_key, new_dek_version),
    do: rewrap_vault_name_columns(vault, old_dek, new_dek, new_filter_key, new_dek_version)

  defp slug_hmac_update(:name, name, vault, filter_key),
    do: [{:slug_hmac, Crypto.hmac_field(filter_key, Engram.Vaults.derive_slug(name, vault))}]

  defp slug_hmac_update(_column, _plaintext, _vault, _filter_key), do: []

  defp rewrap_vault_name_columns(
         %Engram.Vaults.Vault{} = vault,
         old_dek,
         new_dek,
         new_filter_key,
         new_dek_version
       ) do
    [
      {:name, :name_ciphertext, :name_nonce, :name_hmac}
    ]
    |> Enum.flat_map(fn {column, ct_field, nonce_field, hmac_key} ->
      ct = Map.get(vault, ct_field)
      nonce = Map.get(vault, nonce_field)

      if is_nil(ct) or is_nil(nonce) do
        []
      else
        old_aad = old_aad_for(:vaults, column, vault)
        new_aad = Crypto.aad_for_row(:vaults, column, vault.id)

        case try_rewrap(ct, nonce, old_dek, new_dek, old_aad, new_aad,
               table: :vaults,
               phase: :sweep_vaults,
               log: "T3.7 sweep_vaults: decrypt failed under both old and new DEK",
               log_meta: [user_id: vault.user_id, row_id: vault.id, column: column],
               on_both_failed:
                 {:raise,
                  "T3.7 sweep_vaults: decrypt failed under both old and new DEK " <>
                    "for vault id=#{vault.id} column=#{column} new_dek_version=#{new_dek_version}"}
             ) do
          {:ok, plaintext} ->
            {new_ct, new_nonce} = Envelope.encrypt(plaintext, new_dek, new_aad)

            [
              {ct_field, new_ct},
              {nonce_field, new_nonce},
              {hmac_key, Crypto.hmac_field(new_filter_key, plaintext)}
              | slug_hmac_update(column, plaintext, vault, new_filter_key)
            ]

          :already_rotated ->
            # Already rotated under this run's new_dek — skip
            []
        end
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Frontmatter key dictionary sweep
  # ---------------------------------------------------------------------------
  #
  # Every key name is rewrapped under the new DEK and its `key_hmac`
  # recomputed under the new filter key; the ids stay (`FrontmatterKeys`).
  # Old DEK, then new (already rotated by a crashed run, skip); a row neither
  # opens raises like the other DB sweeps. A skipped row would keep an
  # old-key HMAC nobody can match and get the same key a second id.
  defp sweep_frontmatter_keys(%User{id: user_id}, old_dek, new_dek, new_filter_key) do
    uid = to_string(user_id)

    {:ok, _} =
      Repo.with_tenant(uid, fn ->
        for key <- FrontmatterKeys.all(uid) do
          aad = FrontmatterKeys.name_aad(uid, key.key_id)

          case try_rewrap(key.name_ct, key.name_nonce, old_dek, new_dek, aad, aad,
                 table: :frontmatter_keys,
                 phase: :sweep_frontmatter_keys,
                 log: "T3.7 sweep_frontmatter_keys: decrypt failed under both old and new DEK",
                 log_meta: [user_id: uid, key_id: key.key_id],
                 on_both_failed:
                   {:raise,
                    "T3.7 sweep_frontmatter_keys: decrypt failed under both old and new DEK " <>
                      "for key_id=#{key.key_id}"}
               ) do
            {:ok, name} -> FrontmatterKeys.put_rotated(key, name, new_dek, new_filter_key)
            :already_rotated -> :ok
          end
        end
      end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Shared dual-DEK rewrap discriminator
  # ---------------------------------------------------------------------------
  #
  # Every rewrap site funnels through this. Decrypt order is load-bearing:
  # OLD DEK first (row still under the old key — caller re-encrypts under the
  # new DEK), then NEW DEK (row already rotated by a prior crashed run —
  # caller skips). If BOTH fail the row is unrecoverable: structured log +
  # [:engram, :crypto, :rotate, :dek, :row_failed] telemetry, then either
  # raise (DB/S3 sweeps) or return {:error, reason} (Qdrant sweep) per
  # `:on_both_failed`. Site-specific AAD pairs, log/raise text, and telemetry
  # table/phase are passed in so no site is silently harmonized.
  #
  # Returns {:ok, plaintext} | :already_rotated | {:error, term()} (or raises,
  # per :on_both_failed). No @spec: a hand-written one is a dialyzer
  # contract_supertype against the inferred per-site success typing.
  defp try_rewrap(ct, nonce, old_dek, new_dek, old_aad, new_aad, opts) do
    case Envelope.decrypt(ct, nonce, old_dek, old_aad) do
      # Verify mode (`verify_point_text/1`): one key, nothing to rewrap.
      {:ok, _plaintext} when old_dek == new_dek ->
        :already_rotated

      {:ok, plaintext} ->
        # Row was under old DEK — caller re-encrypts with the new DEK
        {:ok, plaintext}

      :error ->
        # Try new DEK — row may already be rotated from a prior crashed run
        case Envelope.decrypt(ct, nonce, new_dek, new_aad) do
          {:ok, _plaintext} ->
            :already_rotated

          :error ->
            both_deks_failed(opts)
        end
    end
  end

  defp both_deks_failed(opts) do
    table = Keyword.fetch!(opts, :table)
    phase = Keyword.fetch!(opts, :phase)

    Logger.error(
      Keyword.fetch!(opts, :log),
      Metadata.with_category(
        :error,
        :crypto,
        Keyword.fetch!(opts, :log_meta) ++
          [table: table, phase: phase, status: :both_deks_failed]
      )
    )

    :telemetry.execute(
      [:engram, :crypto, :rotate, :dek, :row_failed],
      %{count: 1},
      %{table: table, phase: phase, status: :both_deks_failed}
    )

    case Keyword.fetch!(opts, :on_both_failed) do
      {:raise, msg} -> raise msg
      {:error, _reason} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Attachments sweep (two-phase commit per blob)
  # ---------------------------------------------------------------------------
  #
  # Content ciphertext lives in S3, not in the DB — so we cannot do a simple
  # batch UPDATE like notes/vaults. Each attachment requires:
  #   Txn 1: mark dek_version_pending = new_dek_version  (crash-resume marker)
  #   S3 op: GET old ciphertext → decrypt(old_dek) → encrypt(new_dek) → PUT
  #   Txn 2: dek_version = new_dek_version, dek_version_pending = nil,
  #           rewrap path_ciphertext/path_nonce + recompute path_hmac
  #
  # The cursor query picks up rows where either dek_version < new_dek_version OR
  # dek_version_pending == new_dek_version so a crash after Txn 1 is re-tried.
  # Since we now iterate ALL rows (no dek_version filter on the cursor), rows
  # already rotated (dek_version == new_dek_version) are naturally skipped by
  # the decrypt-as-discriminator logic in recrypt_blob.

  defp sweep_attachments(%User{id: user_id}, old_dek, new_dek, new_filter_key, new_dek_version) do
    sweep_attachment_loop(
      user_id,
      new_dek_version,
      old_dek,
      new_dek,
      new_filter_key,
      "00000000-0000-0000-0000-000000000000"
    )
  end

  defp sweep_attachment_loop(user_id, new_dek_version, old_dek, new_dek, new_filter_key, last_id) do
    # Cursor only. The per-attachment work below does S3 I/O, which must not
    # run inside a transaction, so each of its DB steps takes its own tenant
    # scope instead of inheriting one from here.
    {:ok, ids} =
      Repo.with_tenant(user_id, fn ->
        from(a in Engram.Attachments.Attachment,
          where: a.user_id == ^user_id and a.id > ^last_id,
          where: is_nil(a.deleted_at),
          order_by: a.id,
          limit: ^@batch_size,
          select: a.id
        )
        |> Repo.all(skip_tenant_check: true)
      end)

    case ids do
      [] ->
        :ok

      _ ->
        result =
          Enum.reduce_while(ids, :ok, fn id, :ok ->
            case rotate_one_attachment(
                   user_id,
                   id,
                   new_dek_version,
                   old_dek,
                   new_dek,
                   new_filter_key
                 ) do
              :ok -> {:cont, :ok}
              {:error, _} = err -> {:halt, err}
            end
          end)

        case result do
          :ok ->
            sweep_attachment_loop(
              user_id,
              new_dek_version,
              old_dek,
              new_dek,
              new_filter_key,
              List.last(ids)
            )

          {:error, _} = err ->
            err
        end
    end
  end

  defp rotate_one_attachment(user_id, att_id, new_dek_version, old_dek, new_dek, new_filter_key) do
    with {:ok, _} <- mark_pending(user_id, att_id, new_dek_version),
         {:ok, attachment, recrypt_result} <-
           recrypt_blob(user_id, att_id, old_dek, new_dek, new_dek_version) do
      finalize_attachment(
        attachment,
        new_dek_version,
        old_dek,
        new_dek,
        new_filter_key,
        recrypt_result
      )
    end
  end

  defp mark_pending(user_id, att_id, new_dek_version) do
    Repo.with_tenant(user_id, fn ->
      case from(a in Engram.Attachments.Attachment, where: a.id == ^att_id)
           |> Repo.update_all([set: [dek_version_pending: new_dek_version]],
             skip_tenant_check: true
           ) do
        {1, _} ->
          :ok

        {0, _} ->
          Logger.error(
            "T3.7 mark_pending: row vanished during rotation",
            Metadata.with_category(:error, :crypto,
              table: :attachments,
              row_id: att_id,
              phase: :mark_pending
            )
          )

          Repo.rollback({:row_vanished, :attachments, att_id, :mark_pending})
      end
    end)
    |> case do
      {:ok, :ok} -> {:ok, :ok}
      {:error, reason} -> {:error, reason}
    end
  end

  # Returns {:ok, attachment, {:rotated, new_nonce}} when S3 PUT succeeded (blob now under new DEK)
  # Returns {:ok, attachment, :already_rotated} when blob is already under new DEK (prior crashed run)
  defp recrypt_blob(user_id, att_id, old_dek, new_dek, new_dek_version) do
    # Storage MatchError fix: use Repo.one/2 + nil case for concurrent hard-delete safety
    #
    # Tenant scope ends with this read: everything below it is S3 I/O, which
    # has no business inside a transaction.
    {:ok, attachment} =
      Repo.with_tenant(user_id, fn ->
        case Repo.one(
               from(a in Engram.Attachments.Attachment, where: a.id == ^att_id),
               skip_tenant_check: true
             ) do
          nil ->
            Logger.error(
              "T3.7 recrypt_blob: attachment row vanished",
              Metadata.with_category(:error, :crypto,
                table: :attachments,
                row_id: att_id,
                phase: :recrypt_blob
              )
            )

            raise "T3.7 sweep_attachments: attachment row vanished att_id=#{att_id}"

          %Engram.Attachments.Attachment{} = a ->
            a
        end
      end)

    if attachment.encryption_version == 2,
      do: rewrap_file_key(attachment, old_dek, new_dek, new_dek_version),
      else: recrypt_v1_blob(attachment, old_dek, new_dek, new_dek_version)
  end

  # Format v2: the DEK wraps only the per-file key. Rewrapping those 32 bytes
  # is the whole rotation; the blob is never read or written.
  defp rewrap_file_key(attachment, old_dek, new_dek, new_dek_version) do
    att_id = attachment.id
    aad = Crypto.aad_for_row(:attachments, :file_key, att_id)

    case try_rewrap(
           attachment.wrapped_file_key,
           attachment.file_key_nonce,
           old_dek,
           new_dek,
           aad,
           aad,
           table: :attachments,
           phase: :sweep_attachments_file_key,
           log: "T3.7 sweep_attachments: file key unwrap failed under both old and new DEK",
           log_meta: [user_id: attachment.user_id, row_id: att_id, column: :wrapped_file_key],
           on_both_failed:
             {:raise,
              "T3.7 sweep_attachments: file key unwrap failed under both old and new DEK " <>
                "for att id=#{att_id} new_dek_version=#{new_dek_version}"}
         ) do
      {:ok, file_key} ->
        {wrapped, nonce} = SegmentedCipher.wrap_key(file_key, new_dek, att_id)
        {:ok, attachment, {:rewrapped_key, wrapped, nonce}}

      :already_rotated ->
        {:ok, attachment, :already_rotated}
    end
  end

  defp recrypt_v1_blob(attachment, old_dek, new_dek, new_dek_version) do
    att_id = attachment.id

    ct =
      case Engram.Storage.adapter().get(attachment.storage_key) do
        {:ok, blob} ->
          blob

        {:error, reason} ->
          Logger.error(
            "T3.7 recrypt_blob: storage get failed",
            Metadata.with_category(:error, :crypto,
              table: :attachments,
              row_id: att_id,
              storage_key: attachment.storage_key,
              reason_label: Metadata.safe_reason(reason)
            )
          )

          raise "T3.7 sweep_attachments: storage get failed att_id=#{att_id} reason=#{inspect(reason)}"
      end

    old_aad = old_aad_for(:attachments, :content, attachment)
    new_aad = Crypto.aad_for_row(:attachments, :content, attachment.id)

    case try_rewrap(ct, attachment.content_nonce, old_dek, new_dek, old_aad, new_aad,
           table: :attachments,
           phase: :sweep_attachments_blob,
           log: "T3.7 sweep_attachments: S3 blob decrypt failed under both old and new DEK",
           log_meta: [user_id: attachment.user_id, row_id: att_id, column: :content],
           on_both_failed:
             {:raise,
              "T3.7 sweep_attachments: S3 blob decrypt failed under both old and new DEK " <>
                "for att id=#{att_id} new_dek_version=#{new_dek_version}"}
         ) do
      {:ok, plaintext} ->
        # Row was under old DEK — re-encrypt with new DEK and PUT to S3
        {new_ct, new_nonce} = Envelope.encrypt(plaintext, new_dek, new_aad)

        case Engram.Storage.adapter().put(attachment.storage_key, new_ct,
               content_type: attachment.mime_type
             ) do
          :ok -> {:ok, attachment, {:rotated, new_nonce}}
          {:error, _} = err -> err
        end

      :already_rotated ->
        # Already rotated — skip the S3 PUT, just finalize the DB row
        {:ok, attachment, :already_rotated}
    end
  end

  defp finalize_attachment(
         %Engram.Attachments.Attachment{} = attachment,
         new_dek_version,
         old_dek,
         new_dek,
         new_filter_key,
         recrypt_result
       ) do
    Repo.with_tenant(attachment.user_id, fn ->
      meta_updates =
        rewrap_attachment_metadata_columns(
          attachment,
          old_dek,
          new_dek,
          new_filter_key,
          new_dek_version
        )

      nonce_update =
        case recrypt_result do
          {:rotated, new_content_nonce} -> [content_nonce: new_content_nonce]
          {:rewrapped_key, wrapped, nonce} -> [wrapped_file_key: wrapped, file_key_nonce: nonce]
          :already_rotated -> []
        end

      case from(a in Engram.Attachments.Attachment, where: a.id == ^attachment.id)
           |> Repo.update_all(
             [
               set:
                 meta_updates ++
                   nonce_update ++
                   [
                     dek_version: new_dek_version,
                     dek_version_pending: nil
                   ]
             ],
             skip_tenant_check: true
           ) do
        {1, _} ->
          :ok

        {0, _} ->
          Logger.error(
            "T3.7 finalize_attachment: row vanished during rotation",
            Metadata.with_category(:error, :crypto,
              table: :attachments,
              row_id: attachment.id,
              phase: :finalize_attachment
            )
          )

          Repo.rollback({:row_vanished, :attachments, attachment.id, :finalize_attachment})
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp rewrap_attachment_metadata_columns(
         %Engram.Attachments.Attachment{} = att,
         old_dek,
         new_dek,
         new_filter_key,
         new_dek_version
       ) do
    [{:path, :path_ciphertext, :path_nonce, :path_hmac}]
    |> Enum.flat_map(fn {column, ct_field, nonce_field, hmac_field_key} ->
      ct = Map.get(att, ct_field)
      nonce = Map.get(att, nonce_field)

      if is_nil(ct) or is_nil(nonce) do
        []
      else
        old_aad = old_aad_for(:attachments, column, att)
        new_aad = Crypto.aad_for_row(:attachments, column, att.id)

        case try_rewrap(ct, nonce, old_dek, new_dek, old_aad, new_aad,
               table: :attachments,
               phase: :sweep_attachments_metadata,
               log: "T3.7 sweep_attachments: metadata decrypt failed under both old and new DEK",
               log_meta: [user_id: att.user_id, row_id: att.id, column: column],
               on_both_failed:
                 {:raise,
                  "T3.7 sweep_attachments: metadata decrypt failed under both old and new DEK " <>
                    "for att id=#{att.id} column=#{column} new_dek_version=#{new_dek_version}"}
             ) do
          {:ok, plaintext} ->
            {new_ct, new_nonce} = Envelope.encrypt(plaintext, new_dek, new_aad)

            # T4-deferred Critical (#591): same basename_hmac rebuild as
            # notes' `path` column — attachments are link targets too
            # (embeds), and their basename_hmac must track the new filter key.
            basename_updates =
              if column == :path and is_binary(plaintext) do
                [
                  {:basename_hmac,
                   Crypto.hmac_field(new_filter_key, Engram.Links.basename_key(plaintext))}
                  | Engram.Links.path_keys(new_filter_key, plaintext, new_nonce)
                ]
              else
                []
              end

            [
              {ct_field, new_ct},
              {nonce_field, new_nonce},
              {hmac_field_key, Crypto.hmac_field(new_filter_key, plaintext)}
            ] ++ basename_updates

          :already_rotated ->
            # Already rotated — skip
            []
        end
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # attachment_uploads sweep: in-flight chunked upload sessions
  # ---------------------------------------------------------------------------
  #
  # A session holds the file key its parts are sealed under (wrapped by the
  # DEK, bound to the attachment id it will commit as) and the target path
  # (DEK-encrypted, bound to the session id, plus its filter-key HMAC). Left
  # under the old key, every upload spanning a rotation would fail at its
  # next part or at complete. Rewrapped like any other DEK column; the parts
  # already in storage are sealed under the file key and stay valid.

  defp sweep_attachment_uploads(
         %User{id: user_id},
         old_dek,
         new_dek,
         new_filter_key,
         new_dek_version
       ) do
    TenantSweep.each_batch(user_id, Upload, fn batch_ids ->
      Repo.transaction(fn ->
        # Completed sessions are skipped: nothing reads their key or path
        # again (a repeat complete reads the committed row), and their file
        # key may be bound to a claimed id the commit replaced.
        from(u in Upload,
          where: u.id in ^batch_ids and is_nil(u.completed_at),
          lock: "FOR UPDATE"
        )
        |> Repo.all(skip_tenant_check: true)
        |> Enum.each(&rewrap_upload(&1, old_dek, new_dek, new_filter_key, new_dek_version))
      end)
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp rewrap_upload(%Upload{} = up, old_dek, new_dek, new_filter_key, new_dek_version) do
    key_aad = Crypto.aad_for_row(:attachments, :file_key, up.attachment_id)
    path_aad = Crypto.aad_for_row(:attachment_uploads, :path, up.id)

    opts = fn column ->
      [
        table: :attachment_uploads,
        phase: :sweep_attachment_uploads,
        log: "T3.7 sweep_attachment_uploads: decrypt failed under both old and new DEK",
        log_meta: [user_id: up.user_id, row_id: up.id, column: column],
        on_both_failed:
          {:raise,
           "T3.7 sweep_attachment_uploads: decrypt failed under both old and new DEK " <>
             "for upload id=#{up.id} column=#{column}"}
      ]
    end

    key_updates =
      case try_rewrap(
             up.wrapped_file_key,
             up.file_key_nonce,
             old_dek,
             new_dek,
             key_aad,
             key_aad,
             opts.(:wrapped_file_key)
           ) do
        {:ok, file_key} ->
          {wrapped, nonce} = SegmentedCipher.wrap_key(file_key, new_dek, up.attachment_id)
          [wrapped_file_key: wrapped, file_key_nonce: nonce]

        :already_rotated ->
          []
      end

    path_updates =
      case try_rewrap(
             up.path_ciphertext,
             up.path_nonce,
             old_dek,
             new_dek,
             path_aad,
             path_aad,
             opts.(:path)
           ) do
        {:ok, path} ->
          {ct, nonce} = Envelope.encrypt(path, new_dek, path_aad)

          [
            path_ciphertext: ct,
            path_nonce: nonce,
            path_hmac: Crypto.hmac_field(new_filter_key, path)
          ]

        :already_rotated ->
          []
      end

    # dek_version always: complete refuses a session whose version is not
    # the user's, so it must move even when a prior run rewrapped both.
    from(u in Upload, where: u.id == ^up.id)
    |> Repo.update_all([set: key_updates ++ path_updates ++ [dek_version: new_dek_version]],
      skip_tenant_check: true
    )

    :ok
  end

  # ---------------------------------------------------------------------------
  # note_links sweep (#591 T7) — same cursor-batch shape as sweep_notes/5.
  # Nullable alias/anchor columns are skipped like notes' description/resource;
  # target_text also carries the basename HMAC used for link resolution.
  # ---------------------------------------------------------------------------

  defp sweep_note_links(%User{id: user_id}, old_dek, new_dek, new_filter_key, new_dek_version) do
    TenantSweep.each_batch(
      user_id,
      Engram.Links.NoteLink,
      fn batch_ids ->
        Repo.transaction(fn ->
          links =
            from(l in Engram.Links.NoteLink,
              where: l.id in ^batch_ids,
              lock: "FOR UPDATE"
            )
            |> Repo.all(skip_tenant_check: true)

          Enum.each(links, fn link ->
            updates =
              rewrap_note_link_columns(link, old_dek, new_dek, new_filter_key, new_dek_version)

            if updates != [] do
              case from(l in Engram.Links.NoteLink, where: l.id == ^link.id)
                   |> Repo.update_all(
                     [set: updates ++ [dek_version: new_dek_version]],
                     skip_tenant_check: true
                   ) do
                {1, _} ->
                  :ok

                {0, _} ->
                  Logger.error(
                    "T3.7 sweep_note_links: row vanished during rotation",
                    Metadata.with_category(:error, :crypto,
                      user_id: user_id,
                      table: :note_links,
                      row_id: link.id,
                      phase: :sweep_note_links
                    )
                  )

                  raise "T3.7 sweep_note_links: row vanished mid-rotation table=note_links row_id=#{link.id}"
              end
            end
          end)
        end)
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    )
  end

  defp rewrap_note_link_columns(
         %Engram.Links.NoteLink{} = link,
         old_dek,
         new_dek,
         new_filter_key,
         new_dek_version
       ) do
    [
      {:target_text, :target_text_ciphertext, :target_text_nonce, :target_basename_hmac,
       &Engram.Links.basename_key/1},
      {:alias, :alias_ciphertext, :alias_nonce, nil, nil},
      {:anchor, :anchor_ciphertext, :anchor_nonce, nil, nil}
    ]
    |> Enum.flat_map(fn {column, ct_field, nonce_field, hmac_key, hmac_transform} ->
      ct = Map.get(link, ct_field)
      nonce = Map.get(link, nonce_field)

      if is_nil(ct) or is_nil(nonce) do
        []
      else
        old_aad = old_aad_for(:note_links, column, link)
        new_aad = Crypto.aad_for_row(:note_links, column, link.id)

        case try_rewrap(ct, nonce, old_dek, new_dek, old_aad, new_aad,
               table: :note_links,
               phase: :sweep_note_links,
               log: "T3.7 sweep_note_links: decrypt failed under both old and new DEK",
               log_meta: [user_id: link.user_id, row_id: link.id, column: column],
               on_both_failed:
                 {:raise,
                  "T3.7 sweep_note_links: decrypt failed under both old and new DEK " <>
                    "for note_link id=#{link.id} column=#{column} new_dek_version=#{new_dek_version}"}
             ) do
          {:ok, plaintext} ->
            {new_ct, new_nonce} = Envelope.encrypt(plaintext, new_dek, new_aad)

            ct_updates = [{ct_field, new_ct}, {nonce_field, new_nonce}]

            hmac_updates =
              if hmac_key && is_binary(plaintext) do
                [
                  {hmac_key, Crypto.hmac_field(new_filter_key, hmac_transform.(plaintext))}
                  | Engram.Links.target_keys(new_filter_key, plaintext, new_nonce)
                ]
              else
                []
              end

            ct_updates ++ hmac_updates

          :already_rotated ->
            []
        end
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Qdrant sweep — re-encrypt payload fields under the new DEK
  # ---------------------------------------------------------------------------
  #
  # Qdrant points carry three encrypted payload fields: `text`, `title`,
  # `heading_path` (each with a `*_nonce` sibling). We scroll all points for
  # the user (filter: user_id == X), re-encrypt each field with the new DEK,
  # then call set_payload to overwrite the payload keys in place. Vectors are
  # NOT touched (`with_vector: false`).
  #
  # Decrypt-as-discriminator: try old DEK first; fall through to new DEK for
  # resume (a prior crashed run already rotated this point); if both fail,
  # raise. If every field in a point is already under the new DEK, return
  # :unchanged and skip the set_payload call entirely.

  # Every key the index matches on derives from the DEK, and nothing
  # re-indexes after a rotation, so the index is handed over AFTER the flip.
  # Before it, the new DEK lives only in this process: any failure between
  # `sweep_notes` and `final_flip` leaves the notes under a key that was
  # never saved, and the retry mints another one. No Qdrant call sits in
  # that window any more; the S3 I/O in `sweep_attachments` still does
  # (#1507: persist the pending wrapped DEK before `sweep_notes`).
  #
  # * Filter HMACs on the points (`path/folder/tags/type_hmac`, from
  #   `Crypto.dek_filter_key/1`) and keyword (sparse) vectors (dimensions are
  #   filter-key HMACs of the tokens): `final_flip` itself NULLs
  #   `payload_hash` and `keyword_version` and enqueues
  #   `ReconcileNotePayloads`, in its own transaction, so neither depends on
  #   anything below. `ReconcileEmbeddings` then enqueues
  #   `RefreshKeywordVectors` (resparse in place, no embedder).
  # * Chunk reuse (here): `chunks.context_hmac` is keyed on the content-hash
  #   subkey (`Crypto.dek_content_hash_key/1`). Cleared (the old behaviour),
  #   the next index of any note re-embedded every chunk. It is remapped
  #   old-key -> new-key through the fingerprints the note's current text
  #   produces, while the old key is still in memory. DB only, $0 in Voyage.
  #
  # `notes.content_hash` stays on the old key ON PURPOSE: the plugin sends it
  # back as `base_hash`, so moving it would turn every synced client's next
  # push into a 409. It moves to the new key with the note's next write, as
  # `embed_hash` does with it (they stay equal, so EmbedNote still skips).
  #
  # Every filter key derives from the DEK (`Crypto.dek_filter_key/1`), so a
  # rotation changes every HMAC a Qdrant filter matches on: `path/folder/
  # tags/type_hmac` on v3 points, the short ids on v5 points, and the
  # `note_attrs` rows. Nothing re-indexes after a rotation, and a re-index
  # would re-embed every chunk, so the keys are rewritten here from the
  # rotated rows and the decrypted frontmatter. No embedder call: a rotation
  # costs $0 in Voyage.
  #
  # Split by where it writes, so nothing network-bound runs between the
  # rewrap and the flip. `note_attrs` is DB only: rewritten here, before the
  # flip like every other DB sweep (after `sweep_notes` recomputed the row
  # HMACs and `sweep_frontmatter_keys/4` rekeyed the dictionary). The points
  # are Qdrant: `ReconcileNotePayloads`, which the flip commits with itself,
  # rewrites v3 and v5 filter keys from the rows as they are when it runs, so
  # a node dying after the flip loses nothing and a later edit is not
  # reverted.
  defp resync_note_attrs(%User{id: user_id}, new_dek, new_filter_key) do
    TenantSweep.each_batch(
      user_id,
      Engram.Notes.Note,
      fn batch_ids ->
        {:ok, notes} =
          Repo.with_tenant(user_id, fn ->
            Repo.all(from(n in Engram.Notes.Note, where: n.id in ^batch_ids))
          end)

        rewrite_note_attrs(user_id, notes, note_flats(user_id, notes, new_dek, new_filter_key))
      end,
      fun_in_tenant: false
    )
  end

  defp note_flats(user_id, notes, new_dek, new_filter_key),
    do: Map.new(notes, &{&1.id, flat_fields(user_id, &1, new_dek, new_filter_key)})

  # Key ids survive a rotation (`sweep_frontmatter_keys/4` already rekeyed
  # the dictionary), so resolving under the new filter key finds the same ids.
  defp flat_fields(user_id, note, new_dek, new_filter_key) do
    aad = Crypto.aad_for_row(:notes, :content, note.id)

    case note.content_ciphertext &&
           Envelope.decrypt(note.content_ciphertext, note.content_nonce, new_dek, aad) do
      {:ok, content} ->
        flat = FlatFields.extract(content, new_filter_key)
        {ids, _skipped} = FrontmatterKeys.resolve(user_id, new_dek, flat.names)
        FlatFields.put_key_ids(flat, ids)

      _ ->
        FlatFields.empty()
    end
  end

  # `note_attrs` HMACs are under the old key, so the rows are rebuilt from
  # the decrypted frontmatter under the new one.
  defp rewrite_note_attrs(user_id, notes, flats) do
    ids = Enum.map(notes, & &1.id)

    {:ok, _} =
      Repo.with_tenant(user_id, fn ->
        Repo.delete_all(from(a in Engram.Notes.NoteAttr, where: a.note_id in ^ids))

        _inserted =
          for note <- notes, flat = flats[note.id], flat != nil do
            Repo.insert_all(Engram.Notes.NoteAttr, FlatFields.attr_rows(flat, note))
          end

        # The seq does not move here: drop catalogs built on the old rows.
        notes |> Enum.map(& &1.vault_id) |> Enum.uniq() |> Enum.each(&FieldCatalog.evict/1)
      end)

    :ok
  end

  # Task 11.1: a point's display envelope (`chunk_points.display_ct`, notes
  # over the display threshold only), bound to its point id. Only the
  # envelope is rewrapped: `slice_sum` and the offsets hold no plaintext and
  # no key. The
  # AAD does not change across a rotation, only the key. Old-then-new, so a
  # resumed rotation skips rows it already re-wrapped. A row unreadable under
  # both keys is NULLed rather than aborting the rotation: search then
  # re-derives the text from the note content, and the next index pass
  # writes the envelope again.
  defp sweep_chunk_texts(%User{id: user_id}, old_dek, new_dek) do
    TenantSweep.each_batch(user_id, Engram.Notes.ChunkPoint, fn batch_ids ->
      Repo.transaction(fn ->
        from(c in Engram.Notes.ChunkPoint,
          where: c.point_id in ^batch_ids and not is_nil(c.display_ct),
          lock: "FOR UPDATE"
        )
        |> Repo.all(skip_tenant_check: true)
        |> Enum.each(&rewrap_chunk_text(&1, user_id, old_dek, new_dek))
      end)
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp rewrap_chunk_text(chunk, user_id, old_dek, new_dek) do
    sets =
      case Crypto.decrypt_chunk_text(chunk, old_dek, chunk.point_id) do
        {:ok, {text, heading}} ->
          new_ck = Crypto.dek_content_hash_key_from_bytes(new_dek)

          Map.to_list(Crypto.encrypt_chunk_text(text, heading, new_dek, chunk.point_id)) ++
            [slice_sum: Indexing.text_sum(new_ck, text)]

        :error ->
          case Crypto.decrypt_chunk_text(chunk, new_dek, chunk.point_id) do
            {:ok, _} ->
              nil

            :error ->
              _ =
                both_deks_failed(
                  table: :chunks,
                  phase: :sweep_chunk_texts,
                  log: "T3.7 sweep_chunk_texts: decrypt failed under both old and new DEK",
                  log_meta: [user_id: user_id, row_id: chunk.point_id],
                  on_both_failed: {:error, :both_deks_failed}
                )

              [display_ct: nil]
          end
      end

    write_chunk_text(chunk.point_id, sets)
  end

  # `slice_sum` is keyed by the content-hash subkey (`Indexing.text_sum/2`),
  # so every checksum-only row is re-summed under the new key from the text
  # search would show for it: the note content (already swept, so under the
  # new DEK) re-chunked as the read path does (`Indexing.display_chunks/3`).
  # An envelope row was re-summed with its rewrap above. A floor row's text
  # is "" by construction (never re-derived). Resumable: a row already
  # re-summed recomputes to the same value. A note that does not decrypt
  # keeps its row as is; search then shows it stale or not at all, and its
  # next index pass writes a fresh sum. ponytail: one UPDATE per row; a
  # rotation is rare. Batch it with a VALUES join if rotations get large.
  defp sweep_slice_sums(%User{id: user_id}, old_dek, new_dek) do
    old_floor = Indexing.text_sum(Crypto.dek_content_hash_key_from_bytes(old_dek), "")
    new_ck = Crypto.dek_content_hash_key_from_bytes(new_dek)
    new_floor = Indexing.text_sum(new_ck, "")

    # By NOTE: the ChunkPoint cursor (`TenantSweep`) visits only envelope
    # rows, and these are the rows without one. The batch runs in the tenant.
    TenantSweep.each_batch(user_id, Engram.Notes.Note, fn note_ids ->
      rows =
        from(c in Engram.Notes.ChunkPoint,
          where: c.note_id in ^note_ids and is_nil(c.display_ct) and not is_nil(c.slice_sum),
          select: %{
            point_id: c.point_id,
            note_id: c.note_id,
            position: c.position,
            sum: c.slice_sum
          }
        )
        |> Repo.all()

      derived = rows |> Enum.map(& &1.note_id) |> Enum.uniq() |> derived_display(new_dek)

      Enum.each(rows, fn row ->
        sum =
          cond do
            row.sum in [old_floor, new_floor] ->
              new_floor

            text = get_in(derived, [row.note_id, row.position, :text]) ->
              Indexing.text_sum(new_ck, text)

            true ->
              row.sum
          end

        if sum != row.sum, do: write_chunk_text(row.point_id, slice_sum: sum)
      end)
    end)
  end

  # note_id => %{position => %{text, heading_path}}, for the notes that decrypt.
  defp derived_display([], _dek), do: %{}

  defp derived_display(note_ids, dek) do
    from(n in Engram.Notes.Note,
      where: n.id in ^note_ids,
      select:
        {n.id, n.content_ciphertext, n.content_nonce, n.path_ciphertext, n.path_nonce,
         fragment("(SELECT count(*) FROM chunk_points p WHERE p.note_id = ?)", n.id)}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {id, content_ct, content_nonce, path_ct, path_nonce, count} ->
      with true <- is_binary(content_ct) and is_binary(path_ct),
           {:ok, content} <-
             Envelope.decrypt(
               content_ct,
               content_nonce,
               dek,
               Crypto.aad_for_row(:notes, :content, id)
             ),
           {:ok, path} <-
             Envelope.decrypt(path_ct, path_nonce, dek, Crypto.aad_for_row(:notes, :path, id)) do
        [{id, Indexing.display_chunks(content, path, count)}]
      else
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp write_chunk_text(_id, nil), do: :ok

  defp write_chunk_text(id, sets) do
    {_, _} =
      from(c in Engram.Notes.ChunkPoint, where: c.point_id == ^id)
      |> Repo.update_all([set: sets], skip_tenant_check: true)

    :ok
  end

  # The user is unlocked by now, so an edit can index first. That edit pays
  # for its own changed chunks; at worst its untouched chunks re-embed once
  # if it lands before the remap.
  defp post_flip_index_repairs(%User{id: user_id} = user, old_dek, new_dek) do
    case remap_fingerprints(user, old_dek, new_dek) do
      :ok -> :ok
      {:error, reason} -> post_flip_failed(user_id, Metadata.safe_reason(reason))
    end
  rescue
    e -> post_flip_failed(user_id, Metadata.safe_reason(e))
  catch
    kind, reason when kind in [:exit, :throw] ->
      post_flip_failed(user_id, Metadata.safe_exit_reason(reason))
  end

  # The rotation already committed, and the heals were enqueued by the flip.
  # What is lost is cost, not data: unremapped chunks re-embed on their
  # note's next index.
  defp post_flip_failed(user_id, reason) do
    Logger.error(
      "T3.7 post-flip fingerprint remap failed",
      Metadata.with_category(:error, :crypto,
        user_id: user_id,
        phase: :post_flip_index_repairs,
        reason_label: reason
      )
    )

    :telemetry.execute(
      [:engram, :crypto, :rotate, :dek, :row_failed],
      %{count: 1},
      %{table: :chunks, phase: :post_flip_index_repairs, status: :remap_failed}
    )

    :ok
  end

  defp remap_fingerprints(%User{id: user_id}, old_dek, new_dek) do
    keys =
      {Crypto.dek_content_hash_key_from_bytes(old_dek),
       Crypto.dek_content_hash_key_from_bytes(new_dek)}

    TenantSweep.each_batch(
      user_id,
      Engram.Notes.Note,
      fn batch_ids -> remap_batch(user_id, batch_ids, new_dek, keys) end,
      fun_in_tenant: false
    )
  end

  defp remap_batch(user_id, batch_ids, new_dek, {old_key, new_key}) do
    {:ok, notes} =
      Repo.with_tenant(user_id, fn ->
        Repo.all(from(n in Engram.Notes.Note, where: n.id in ^batch_ids and n.kind == "note"))
      end)

    Enum.each(notes, fn note ->
      map =
        case Crypto.maybe_decrypt_note_fields_with_dek(note, new_dek) do
          {:ok, plain} -> Indexing.rekey_fingerprints(plain, old_key, new_key)
          # `sweep_notes` already failed loudly on a row that does not decrypt.
          _ -> %{}
        end

      remap_note_chunks(user_id, note.id, map)
    end)
  end

  defp remap_note_chunks(user_id, note_id, map) do
    {olds, news} = Enum.unzip(map)

    {:ok, _} =
      Repo.with_tenant(user_id, fn ->
        # `chunks` carries FORCE ROW LEVEL SECURITY: unscoped, these match
        # zero rows and still return :ok, a silent no-op. A row neither old-
        # nor new-key (text edited since its last index) is cleared, as
        # before; one a post-flip index already wrote under the new key stays.
        {_, _} =
          from(c in Engram.Notes.Chunk,
            where:
              c.note_id == ^note_id and not is_nil(c.context_hmac) and
                c.context_hmac not in ^olds and c.context_hmac not in ^news
          )
          |> Repo.update_all(set: [context_hmac: nil])

        from(c in Engram.Notes.Chunk,
          join:
            m in fragment(
              "SELECT * FROM unnest(?::text[], ?::text[]) AS m(old, new)",
              ^olds,
              ^news
            ),
          on: c.context_hmac == m.old,
          where: c.note_id == ^note_id,
          update: [set: [context_hmac: m.new]]
        )
        |> Repo.update_all([])
      end)

    :ok
  end

  @qdrant_attempts 3
  @qdrant_retry_ms Application.compile_env(:engram, [__MODULE__, :qdrant_retry_ms], 2_000)

  # The point TEXT rewrap, after the flip. Before it, a Qdrant failure here
  # stranded every note under a DEK that was never saved (the retry mints
  # another). After it the notes are safe whatever Qdrant does; the old DEK
  # is still in this process, so a failed page is retried here (the sweep is
  # idempotent: decrypt-as-discriminator skips rewrapped points).
  #
  # Once this returns the old DEK is gone, so a point it did not rewrap keeps
  # text no key can read, and search drops it. Those notes are queued for a
  # rebuild (`requeue_for_rebuild/2`). If this process dies first, the
  # `RotationTextGuard` the flip committed finds them (`verify_point_text/1`).
  #
  # Every page pushes the guard out again (`push_text_guard/1`): while this
  # sweep makes progress the guard never fires, so it never pays Voyage to
  # rebuild notes this sweep is about to rewrap. A dead sweep stops pushing
  # and the guard runs `RotationTextGuard.delay_seconds/0` after its last page.
  defp sweep_qdrant_after_flip(user, old_dek, new_dek, guard, attempt \\ 1) do
    case sweep_qdrant(user, old_dek, new_dek, on_page: fn -> push_text_guard(guard) end) do
      {:ok, [], nil} ->
        :ok

      # Deterministic (the point is under neither key), so not retried.
      {:ok, skipped, nil} ->
        settle_undecryptable(user.id, skipped, :after_flip)

      {:error, _} when attempt < @qdrant_attempts ->
        Process.sleep(@qdrant_retry_ms * attempt)
        sweep_qdrant_after_flip(user, old_dek, new_dek, guard, attempt + 1)

      {:error, reason} ->
        requeue_for_rebuild(user.id, :all, classify_reason(reason))
    end
  rescue
    e -> requeue_for_rebuild(user.id, :all, Metadata.safe_reason(e))
  catch
    kind, reason when kind in [:exit, :throw] ->
      requeue_for_rebuild(user.id, :all, Metadata.safe_exit_reason(reason))
  end

  @doc """
  The point-text check behind `Engram.Workers.RotationTextGuard`: every point
  of `user` whose text does not open under the CURRENT DEK goes the way the
  post-flip sweep sends its skips (`settle_undecryptable/2`): a live note's
  is rebuilt, unmetered, and an orphan's is deleted. That is what a rotation
  whose process died between its flip and the end of its text sweep leaves
  behind, and the retired DEK that could rewrap them died with it.

  Reads only, unless something is unreadable. A Qdrant failure is
  `{:error, reason}`, for the job to retry: never a whole-vault rebuild.

  At most `max_pages` pages from `offset` (a scroll cursor, nil from the
  start), settled before it returns, so a big vault on a slow Qdrant makes
  durable progress per job instead of rescanning from page 1 on every
  attempt. `{:ok, next}`: nil when the scroll is done, else where the next
  job resumes.
  """
  @spec verify_point_text(User.t(), term(), pos_integer()) ::
          {:ok, term()} | {:error, term()}
  def verify_point_text(%User{} = user, offset, max_pages) do
    with {:ok, dek} <- Crypto.get_dek(user),
         {:ok, skipped, next} <-
           sweep_qdrant(user, dek, dek, offset: offset, max_pages: max_pages) do
      :ok = settle_undecryptable(user.id, skipped, :guard_rebuild)
      {:ok, next}
    end
  end

  # The flip's guard, still scheduled, is due a full delay from now. A guard
  # already running (or done, or cancelled) is left alone.
  defp push_text_guard(%Oban.Job{id: id}) when is_integer(id) do
    due = DateTime.add(DateTime.utc_now(), RotationTextGuard.delay_seconds())

    from(j in Oban.Job, where: j.id == ^id and j.state == "scheduled")
    |> Repo.update_all(set: [scheduled_at: due])

    :ok
  end

  defp push_text_guard(_conflict), do: :ok

  # A skipped point a LIVE note's chunk row names belongs to an index that
  # must be rebuilt. Any other is dead weight: no row names it (an orphan
  # left by a crashed rotation), or its note is trashed, where a rebuild job
  # would only discard. Nothing would ever rebuild or reap those, so they are
  # deleted. The ids come from a scroll filtered to this user, so the delete
  # touches only this user's points.
  defp settle_undecryptable(_user_id, [], _status), do: :ok

  defp settle_undecryptable(user_id, skipped, status) do
    {:ok, named} =
      Repo.with_tenant(user_id, fn ->
        from(c in Engram.Notes.Chunk,
          join: n in Engram.Notes.Note,
          on: n.id == c.note_id,
          where:
            c.user_id == ^user_id and c.qdrant_point_id in ^skipped and n.kind == "note" and
              is_nil(n.deleted_at),
          select: {c.qdrant_point_id, c.note_id}
        )
        |> Repo.all()
      end)

    orphans = skipped -- Enum.map(named, &elem(&1, 0))

    # A failed delete leaves the orphan for the next rotation; it is never
    # read (no row names it), so it costs nothing until then.
    if orphans != [] and :ok == Qdrant.delete_points(Qdrant.collection_name(), orphans) do
      :telemetry.execute(
        [:engram, :crypto, :rotate, :dek, :row_failed],
        %{count: length(orphans)},
        %{table: :qdrant, phase: :sweep_qdrant, status: :orphan_deleted}
      )
    end

    case named do
      [] ->
        :ok

      named ->
        note_ids = named |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
        requeue_for_rebuild(user_id, note_ids, "undecryptable_points:#{length(named)}", status)
    end
  end

  # The point text of these notes is under the retired DEK, which search
  # drops. Their fingerprints are cleared (no point may be reused) and their
  # `chunker_version` NULLed: version-stale with content unchanged is
  # EmbedNote's maintenance path, unmetered and dense-preserving, so a Free
  # user at the cap is not billed for our failure. `embed_hash` is left alone
  # (clearing it meant the metered content path). EmbedNote is enqueued now
  # rather than at the reconcile sweep's daily version hour.
  #
  # Never raises: the rotation is committed by now and must report :ok.
  #
  # `status` labels the row_failed counter: `:after_flip` counts one per
  # incomplete post-flip sweep; `:guard_rebuild` counts the notes a
  # `RotationTextGuard` rebuilt, as that is Voyage we pay with no ledger.
  defp requeue_for_rebuild(user_id, note_ids, reason, status \\ :after_flip) do
    Logger.error(
      "T3.7 sweep_qdrant incomplete after the flip: notes requeued for a rebuild",
      Metadata.with_category(:error, :crypto,
        user_id: user_id,
        phase: :sweep_qdrant,
        reason_label: reason
      )
    )

    count = if status == :guard_rebuild, do: length(note_ids), else: 1

    :telemetry.execute(
      [:engram, :crypto, :rotate, :dek, :row_failed],
      %{count: count},
      %{table: :qdrant, phase: :sweep_qdrant, status: status}
    )

    {:ok, ids} =
      Repo.with_tenant(user_id, fn ->
        notes = from(n in Engram.Notes.Note, where: n.user_id == ^user_id and n.kind == "note")
        notes = if note_ids == :all, do: notes, else: from(n in notes, where: n.id in ^note_ids)

        {_, ids} = Repo.update_all(from(n in notes, select: n.id), set: [chunker_version: nil])

        {_, _} =
          from(c in Engram.Notes.Chunk, where: c.note_id in ^ids and not is_nil(c.context_hmac))
          |> Repo.update_all(set: [context_hmac: nil])

        ids
      end)

    # A pending RebuildStaleNote rebuilds the note too (chunker_version is
    # NULL now), so an EmbedNote beside it would pay Voyage twice.
    ids
    |> EmbedNote.reject_already_queued(EmbedNote.backfill_priority())
    |> then(&Engram.Jobs.reject_pending(Engram.Workers.RebuildStaleNote, &1))
    |> Enum.chunk_every(500)
    |> Enum.each(fn batch ->
      Oban.insert_all(
        Enum.map(
          batch,
          &EmbedNote.new_debounced(&1, user_id, priority: EmbedNote.backfill_priority())
        )
      )
    end)

    :ok
  rescue
    e -> requeue_failed(user_id, Metadata.safe_reason(e))
  catch
    kind, reason when kind in [:exit, :throw] ->
      requeue_failed(user_id, Metadata.safe_exit_reason(reason))
  end

  defp requeue_failed(user_id, reason) do
    Logger.error(
      "T3.7 rebuild requeue failed after the flip: point text left unreadable",
      Metadata.with_category(:error, :crypto,
        user_id: user_id,
        phase: :sweep_qdrant,
        reason_label: reason
      )
    )

    :telemetry.execute(
      [:engram, :crypto, :rotate, :dek, :row_failed],
      %{count: 1},
      %{table: :qdrant, phase: :sweep_qdrant, status: :requeue_failed}
    )

    :ok
  end

  @qdrant_encrypted_fields [:text, :title, :heading_path]
  # Only what the rewrap reads. `set_payloads/2` merges, so writing back just
  # these keys leaves the filter keys alone.
  @qdrant_encrypted_keys Enum.flat_map(@qdrant_encrypted_fields, &[to_string(&1), "#{&1}_nonce"])

  # `{:ok, skipped, next}`: `next` is nil once the scroll is done, else the
  # cursor after `:max_pages` pages. `:on_page` runs after each page.
  #
  # Only legacy-format points hold ciphertext (a v5 payload has none,
  # `Engram.Indexing.PayloadV5`), so the scroll is on the legacy `user_id` key
  # alone: paging the user's v5 points would find nothing to rewrap. Once no
  # legacy point can exist (legacy filters off: the v3 cluster, which has no
  # `user_id` index) there is nothing to sweep and no call is made.
  defp sweep_qdrant(%User{id: user_id}, old_dek, new_dek, opts) do
    if Qdrant.legacy_filter_fields?(),
      do: sweep_legacy_points(user_id, old_dek, new_dek, opts),
      else: {:ok, [], nil}
  end

  defp sweep_legacy_points(user_id, old_dek, new_dek, opts) do
    collection = Qdrant.collection_name()
    filter = %{must: [Qdrant.legacy_match_filter(:user, user_id)]}

    walk = %{
      on_page: Keyword.get(opts, :on_page, fn -> :ok end),
      pages_left: Keyword.get(opts, :max_pages, :infinity)
    }

    sweep_qdrant_loop(
      collection,
      filter,
      user_id,
      {old_dek, new_dek},
      Keyword.get(opts, :offset),
      [],
      walk
    )
  end

  defp sweep_qdrant_loop(collection, filter, user_id, deks, offset, skipped, walk) do
    {old_dek, new_dek} = deks

    case Qdrant.scroll(collection,
           filter: filter,
           with_payload: @qdrant_encrypted_keys,
           with_vector: false,
           limit: 200,
           offset: offset
         ) do
      {:ok, %{points: [], next_page_offset: _}} ->
        {:ok, skipped, nil}

      {:ok, %{points: points, next_page_offset: next}} ->
        case rewrap_qdrant_points(collection, user_id, points, old_dek, new_dek) do
          {:ok, page_skipped} when is_nil(next) ->
            {:ok, page_skipped ++ skipped, nil}

          {:ok, page_skipped} when walk.pages_left == 1 ->
            {:ok, page_skipped ++ skipped, next}

          {:ok, page_skipped} ->
            :ok = walk.on_page.()
            walk = %{walk | pages_left: next_pages_left(walk.pages_left)}

            sweep_qdrant_loop(
              collection,
              filter,
              user_id,
              deks,
              next,
              page_skipped ++ skipped,
              walk
            )

          {:error, _} = err ->
            err
        end

      {:error, reason} ->
        Logger.error(
          "T3.7 sweep_qdrant: scroll failed",
          Metadata.with_category(:error, :crypto,
            user_id: user_id,
            phase: :sweep_qdrant,
            status: :scroll_failed,
            reason_label: Metadata.safe_reason(reason)
          )
        )

        {:error, reason}
    end
  end

  defp next_pages_left(:infinity), do: :infinity
  defp next_pages_left(n), do: n - 1

  # One page, two Qdrant requests whatever its size (`Qdrant.set_payloads/2`):
  # a waited set_payload per point was one WAL flush each, and a ~150k-point
  # user ran past the 60-minute rotation timeout (review M3).
  # Returns `{:ok, skipped_ids}`: a point under neither key (an earlier
  # crashed rotation left it) is skipped, never a halt. Halting stranded
  # every later point under the DEK the flip just retired.
  defp rewrap_qdrant_points(collection, user_id, points, old_dek, new_dek) do
    pairs =
      Enum.reduce_while(points, {:ok, [], []}, fn point, {:ok, acc, skipped} ->
        qdrant_id = point["id"] || missing_point_id!(user_id)
        payload = point["payload"] || %{}

        case rewrap_qdrant_payload(collection, qdrant_id, payload, old_dek, new_dek) do
          {:ok, :unchanged} -> {:cont, {:ok, acc, skipped}}
          {:ok, new_payload} -> {:cont, {:ok, [{qdrant_id, new_payload} | acc], skipped}}
          {:error, {:qdrant_decrypt_failed, _, _}} -> {:cont, {:ok, acc, [qdrant_id | skipped]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    with {:ok, pairs, skipped} <- pairs do
      case Qdrant.set_payloads(collection, Enum.reverse(pairs), caller: :dek_rotation) do
        :ok ->
          {:ok, skipped}

        {:error, reason} ->
          Logger.error(
            "T3.7 sweep_qdrant: set_payload failed",
            Metadata.with_category(:error, :crypto,
              user_id: user_id,
              total_count: length(pairs),
              phase: :sweep_qdrant,
              status: :set_payload_failed,
              reason_label: Metadata.safe_reason(reason)
            )
          )

          {:error, {:qdrant_set_payload_failed, reason}}
      end
    end
  end

  @spec missing_point_id!(term()) :: no_return()
  defp missing_point_id!(user_id) do
    Logger.error(
      "T3.7 sweep_qdrant: point missing id",
      Metadata.with_category(:error, :crypto,
        user_id: user_id,
        phase: :sweep_qdrant,
        status: :missing_id
      )
    )

    :telemetry.execute(
      [:engram, :crypto, :rotate, :dek, :row_failed],
      %{count: 1},
      %{table: :qdrant, phase: :sweep_qdrant, status: :missing_id}
    )

    raise "T3.7 sweep_qdrant: point missing id"
  end

  defp rewrap_qdrant_payload(collection, qdrant_id, payload, old_dek, new_dek) do
    encrypted_fields_present? =
      Enum.any?(@qdrant_encrypted_fields, fn f ->
        Map.has_key?(payload, Atom.to_string(f))
      end)

    if encrypted_fields_present? do
      rewrap_qdrant_payload_fields(collection, qdrant_id, payload, old_dek, new_dek)
    else
      {:ok, :unchanged}
    end
  end

  defp rewrap_qdrant_payload_fields(collection, qdrant_id, payload, old_dek, new_dek) do
    result =
      Enum.reduce_while(@qdrant_encrypted_fields, {:ok, payload, false}, fn field,
                                                                            {:ok, acc,
                                                                             any_changed?} ->
        ct_key = Atom.to_string(field)
        nonce_key = ct_key <> "_nonce"

        ct_b64 = Map.get(acc, ct_key)
        nonce_b64 = Map.get(acc, nonce_key)

        if is_nil(ct_b64) or is_nil(nonce_b64) do
          {:cont, {:ok, acc, any_changed?}}
        else
          ct_bin = Base.decode64!(ct_b64)
          nonce_bin = Base.decode64!(nonce_b64)
          aad = Crypto.aad_for_qdrant(collection, to_string(qdrant_id), field)

          # Qdrant payloads are always AAD-bound: same AAD for both DEK probes.
          case try_rewrap(ct_bin, nonce_bin, old_dek, new_dek, aad, aad,
                 table: :qdrant,
                 phase: :sweep_qdrant,
                 log: "T3.7 sweep_qdrant: decrypt failed under both old and new DEK",
                 log_meta: [qdrant_id: qdrant_id, field: field],
                 on_both_failed: {:error, {:qdrant_decrypt_failed, qdrant_id, field}}
               ) do
            {:ok, plaintext} ->
              {new_ct_bin, new_nonce_bin} = Envelope.encrypt(plaintext, new_dek, aad)

              new_acc =
                acc
                |> Map.put(ct_key, Base.encode64(new_ct_bin))
                |> Map.put(nonce_key, Base.encode64(new_nonce_bin))

              {:cont, {:ok, new_acc, true}}

            :already_rotated ->
              # Already under new DEK from a prior crashed run — leave as-is
              {:cont, {:ok, acc, any_changed?}}

            {:error, _} = err ->
              {:halt, err}
          end
        end
      end)

    case result do
      {:ok, _final_payload, false} ->
        {:ok, :unchanged}

      # Only the keys rewrapped here, never the scrolled payload: the payload
      # heal runs concurrently from the flip on, and writing back the filter
      # HMACs this scroll read would revert the new-key ones it just wrote.
      {:ok, final_payload, true} ->
        {:ok, Map.filter(final_payload, fn {k, v} -> Map.get(payload, k) != v end)}

      {:error, _} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Generic cursor-based sweep loop (notes + vaults)
  # ---------------------------------------------------------------------------

  # The vault index snapshot (#1151). A NEW encrypted table is invisible to this
  # rotation unless it is listed here — the ciphertext would stay wrapped under
  # the OLD dek, decrypt fine until the old key is retired, and then fail. The
  # index is not read by anything today (notes rows still hold the authoritative
  # paths), but that changes at Engram-obsidian#363 — so it is swept like any
  # other encrypted table rather than treated as a cache.
  #
  # No HMAC and no filter key: the snapshot is one opaque blob with no lookup
  # column, which is why this takes fewer arguments than its siblings.
  defp sweep_vault_index_states(%User{id: user_id}, old_dek, new_dek, new_dek_version) do
    TenantSweep.each_batch(
      user_id,
      Engram.Notes.VaultIndexState,
      fn batch_ids ->
        Repo.transaction(fn ->
          rows =
            from(s in Engram.Notes.VaultIndexState,
              where: s.vault_id in ^batch_ids,
              lock: "FOR UPDATE"
            )
            |> Repo.all(skip_tenant_check: true)

          Enum.each(rows, &rewrap_index_state(&1, user_id, old_dek, new_dek, new_dek_version))
        end)
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    )
  end

  defp rewrap_index_state(row, user_id, old_dek, new_dek, new_dek_version) do
    # AAD binds to the vault and does NOT change across a rotation — only the
    # key does. Reusing it on both sides is what keeps the row bound to its vault.
    aad = Crypto.aad_for_row(:vault_index_states, :state, row.vault_id)

    case Envelope.decrypt(row.state_ciphertext, row.state_nonce, old_dek, aad) do
      {:ok, plaintext} ->
        {ct, nonce} = Envelope.encrypt(plaintext, new_dek, aad)

        case from(s in Engram.Notes.VaultIndexState, where: s.vault_id == ^row.vault_id)
             |> Repo.update_all(
               [set: [state_ciphertext: ct, state_nonce: nonce, dek_version: new_dek_version]],
               skip_tenant_check: true
             ) do
          {1, _} ->
            :ok

          {0, _} ->
            Logger.error(
              "T3.7 sweep_vault_index_states: row vanished during rotation",
              Metadata.with_category(:error, :crypto,
                user_id: user_id,
                table: :vault_index_states,
                row_id: row.vault_id,
                phase: :sweep_vault_index_states
              )
            )

            raise "T3.7 sweep_vault_index_states: row vanished mid-rotation vault_id=#{row.vault_id}"
        end

      :error ->
        # Do NOT skip: a row left under the old dek is a row that stops
        # decrypting the moment the old key is retired, and it would do so
        # silently, long after this rotation "succeeded".
        raise "T3.7 sweep_vault_index_states: decrypt failed vault_id=#{row.vault_id}"
    end
  end

  # #1391 — the index TAIL. Rows here are as encrypted as the snapshot and just
  # as load-bearing: they hold every claim made since the last checkpoint, which
  # since #1151 step 2 is committed identity that exists nowhere else. Missing
  # this sweep would leave them under a retiring key, and they would stop
  # decrypting silently long after the rotation reported success.
  #
  # Keyed by the row id (not the vault) because the AAD binds per row.
  defp sweep_vault_index_update_log(%User{id: user_id}, old_dek, new_dek, new_dek_version) do
    TenantSweep.each_batch(
      user_id,
      Engram.Notes.VaultIndexUpdateLog,
      fn batch_ids ->
        Repo.transaction(fn ->
          rows =
            from(l in Engram.Notes.VaultIndexUpdateLog,
              where: l.id in ^batch_ids,
              lock: "FOR UPDATE"
            )
            |> Repo.all(skip_tenant_check: true)

          Enum.each(rows, &rewrap_index_update(&1, user_id, old_dek, new_dek, new_dek_version))
        end)
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    )
  end

  defp rewrap_index_update(row, user_id, old_dek, new_dek, new_dek_version) do
    # AAD binds to the row id and does not change across a rotation, so old and
    # new AAD are the same value here.
    aad = Crypto.aad_for_row(:vault_index_update_log, :update, row.id)

    # old-then-new, like `rewrap_crdt_tail/3`: a rotation RETRIED after a crash
    # meets rows it already re-wrapped, and decrypting under the old key is what
    # discriminates. Raising on those would make a resumed rotation impossible.
    # log/log_meta/on_both_failed are REQUIRED: try_rewrap's failure branch
    # fetch!es all three, so omitting them turns an unreadable row into a
    # KeyError that aborts the rotation after several sweeps have already run
    # and before final_flip — with no row_failed telemetry and nothing naming
    # the row. Same shape as rewrap_crdt_tail/3, the note-tail analogue.
    case try_rewrap(row.update_ciphertext, row.update_nonce, old_dek, new_dek, aad, aad,
           table: :vault_index_update_log,
           phase: :sweep_vault_index_update_log,
           log: "T3.7 sweep_vault_index_update_log: decrypt failed under both old and new DEK",
           log_meta: [user_id: user_id, row_id: row.id],
           on_both_failed: {:error, :both_deks_failed}
         ) do
      :already_rotated ->
        :ok

      # One unreadable tail row must not abort the rotation: try_rewrap has
      # already logged it and emitted row_failed, and there is nothing safe to
      # write. Aborting would strand the user mid-rotation permanently.
      {:error, _reason} ->
        :ok

      {:ok, plaintext} ->
        {ct, nonce} = Envelope.encrypt(plaintext, new_dek, aad)

        case from(l in Engram.Notes.VaultIndexUpdateLog, where: l.id == ^row.id)
             |> Repo.update_all(
               [set: [update_ciphertext: ct, update_nonce: nonce, dek_version: new_dek_version]],
               skip_tenant_check: true
             ) do
          {1, _} ->
            :ok

          # NOT an error here, unlike the snapshot sweep. A checkpoint prunes
          # tail rows by exact id, so a row legitimately disappears mid-rotation
          # whenever a room happens to exit — and its content is already folded
          # into the snapshot the previous sweep step re-wrapped.
          {0, _} ->
            Logger.info(
              "T3.7 sweep_vault_index_update_log: row pruned by a checkpoint mid-rotation",
              Metadata.with_category(:info, :crypto,
                user_id: user_id,
                table: :vault_index_update_log,
                row_id: row.id,
                phase: :sweep_vault_index_update_log
              )
            )

            :ok
        end
    end
  end

  # Re-encrypt all ciphertext column pairs under the new DEK and recompute
  # HMAC-indexed fields from the decrypted plaintext using the new filter key.
  # Uses decrypt-as-discriminator: try old DEK first; if that fails, try new DEK
  # (handles rows already rotated by a prior crashed run); if both fail, raise.
  defp rewrap_note_columns(
         %Engram.Notes.Note{} = note,
         old_dek,
         new_dek,
         new_filter_key,
         new_dek_version
       ) do
    base_columns = [
      {:content, :content_ciphertext, :content_nonce, nil, nil},
      {:title, :title_ciphertext, :title_nonce, nil, nil},
      {:path, :path_ciphertext, :path_nonce, :path_hmac, & &1},
      {:folder, :folder_ciphertext, :folder_nonce, :folder_hmac, & &1},
      {:type, :type_ciphertext, :type_nonce, :type_hmac,
       &Engram.Notes.OkfFields.normalize_type/1},
      {:description, :description_ciphertext, :description_nonce, nil, nil},
      {:resource, :resource_ciphertext, :resource_nonce, nil, nil}
    ]

    base_updates =
      base_columns
      |> Enum.flat_map(fn {column, ct_field, nonce_field, hmac_key, hmac_transform} ->
        ct = Map.get(note, ct_field)
        nonce = Map.get(note, nonce_field)

        if is_nil(ct) or is_nil(nonce) do
          []
        else
          old_aad = old_aad_for(:notes, column, note)

          new_aad = Crypto.aad_for_row(:notes, column, note.id)

          case try_rewrap(ct, nonce, old_dek, new_dek, old_aad, new_aad,
                 table: :notes,
                 phase: :sweep_notes,
                 log: "T3.7 sweep_notes: decrypt failed under both old and new DEK",
                 log_meta: [user_id: note.user_id, row_id: note.id, column: column],
                 on_both_failed:
                   {:raise,
                    "T3.7 sweep_notes: decrypt failed under both old and new DEK " <>
                      "for note id=#{note.id} column=#{column} new_dek_version=#{new_dek_version}"}
               ) do
            {:ok, plaintext} ->
              {new_ct, new_nonce} = Envelope.encrypt(plaintext, new_dek, new_aad)

              ct_updates = [{ct_field, new_ct}, {nonce_field, new_nonce}]

              hmac_updates =
                if hmac_key && is_binary(plaintext) do
                  [{hmac_key, Crypto.hmac_field(new_filter_key, hmac_transform.(plaintext))}]
                else
                  []
                end

              # T4-deferred Critical (#591): `path` also drives note_links
              # resolution via `basename_hmac`. If this isn't rebuilt under
              # the new filter key, every wikilink/embed pointing at this
              # note silently stops resolving post-rotation.
              basename_updates =
                if column == :path and is_binary(plaintext) do
                  [
                    {:basename_hmac,
                     Crypto.hmac_field(new_filter_key, Engram.Links.basename_key(plaintext))}
                    | Engram.Links.path_keys(new_filter_key, plaintext, new_nonce)
                  ]
                else
                  []
                end

              ct_updates ++
                hmac_updates ++
                basename_updates

            :already_rotated ->
              # Already rotated under this run's new_dek — skip
              []
          end
        end
      end)

    tag_updates = rewrap_tags(note, old_dek, new_dek, new_filter_key, new_dek_version)

    # If every column is already rotated (all return []), don't touch the row at all.
    # The caller checks `updates != []` before issuing the UPDATE.
    base_updates ++ tag_updates ++ rewrap_crdt_state(note, old_dek, new_dek)
  end

  # crdt_state is handled apart from base_columns for two reasons. #1341.
  #
  # AAD: `Crypto.encrypt_crdt_state/3` binds to the row id UNCONDITIONALLY -- it
  # has no empty-AAD branch -- so unlike every other column the bind string does
  # NOT follow `dek_version`. Using the bound AAD on both sides is what lets a
  # rotation HEAL a #1336 row (v1 stamped, snapshot already bound) instead of
  # failing to read it.
  #
  # Failure: base_columns RAISES when neither DEK decrypts, which aborts the
  # sweep after earlier batches have already committed under a new DEK that
  # `final_flip/3` has not yet persisted -- unrecoverable. So an unreadable
  # snapshot is LEFT ALONE, exactly as `rewrap_crdt_tail/3` leaves an unreadable
  # delta alone.
  #
  # Left alone, NOT nulled. NULLing reads as the tidier "drop the derived column
  # and let BackfillCrdtState re-seed it", and it is worse: the note's tail log
  # survives -- and `rewrap_crdt_tail/3` has just made that tail READABLE -- so
  # the next bind replays base-less deltas onto an empty doc and the checkpoint
  # materializes that fragment over the body. Seeding from content instead just
  # unions two unrelated Yjs lineages. A snapshot that decrypts under neither DEK
  # was already unreadable before the rotation touched it; leaving it is the only
  # option here that makes nothing worse.
  defp rewrap_crdt_state(%Engram.Notes.Note{crdt_state_ciphertext: nil}, _old_dek, _new_dek),
    do: []

  defp rewrap_crdt_state(%Engram.Notes.Note{crdt_state_nonce: nil}, _old_dek, _new_dek), do: []

  defp rewrap_crdt_state(%Engram.Notes.Note{} = note, old_dek, new_dek) do
    aad = Crypto.aad_for_row(:notes, :crdt_state, note.id)

    case try_rewrap(note.crdt_state_ciphertext, note.crdt_state_nonce, old_dek, new_dek, aad, aad,
           table: :notes,
           phase: :sweep_notes,
           log: "T3.7 sweep_notes: crdt_state decrypt failed under both old and new DEK",
           log_meta: [user_id: note.user_id, row_id: note.id, column: :crdt_state],
           on_both_failed: {:error, :both_deks_failed}
         ) do
      {:ok, plaintext} ->
        {ct, nonce} = Envelope.encrypt(plaintext, new_dek, aad)
        [crdt_state_ciphertext: ct, crdt_state_nonce: nonce]

      :already_rotated ->
        []

      {:error, _reason} ->
        []
    end
  end

  defp rewrap_tags(
         %Engram.Notes.Note{tags_ciphertext: nil},
         _old_dek,
         _new_dek,
         _new_filter_key,
         _new_dek_version
       ),
       do: []

  defp rewrap_tags(%Engram.Notes.Note{} = note, old_dek, new_dek, new_filter_key, new_dek_version) do
    ct = note.tags_ciphertext
    nonce = note.tags_nonce

    if is_nil(ct) or is_nil(nonce) do
      []
    else
      old_aad = old_aad_for(:notes, :tags, note)
      new_aad = Crypto.aad_for_row(:notes, :tags, note.id)

      case try_rewrap(ct, nonce, old_dek, new_dek, old_aad, new_aad,
             table: :notes,
             phase: :sweep_notes,
             log: "T3.7 sweep_notes: decrypt failed under both old and new DEK",
             log_meta: [user_id: note.user_id, row_id: note.id, column: :tags],
             on_both_failed:
               {:raise,
                "T3.7 sweep_notes: decrypt failed under both old and new DEK " <>
                  "for note id=#{note.id} column=tags new_dek_version=#{new_dek_version}"}
           ) do
        {:ok, etf_bin} ->
          # ETF special case: re-encode the decoded term and encrypt THAT,
          # exactly as before (not the raw decrypted binary).
          tags = Engram.Notes.TagsTerm.decode!(etf_bin)
          new_etf = :erlang.term_to_binary(tags)
          {new_ct, new_nonce} = Envelope.encrypt(new_etf, new_dek, new_aad)

          # `TagsTerm.decode!/1` returns the stored tag list.
          tags_hmac = Enum.map(tags, &Crypto.hmac_field(new_filter_key, &1))

          [
            {:tags_ciphertext, new_ct},
            {:tags_nonce, new_nonce},
            {:tags_hmac, tags_hmac}
          ]

        :already_rotated ->
          # Already rotated — skip
          []
      end
    end
  end

  # Derive the correct AAD for an existing encrypted row based on its dek_version.
  # Rows with dek_version < 2 were written with empty AAD (pre-T3.6).
  # The bound 2 mirrors Crypto.@row_version_aad_bound — cannot use a remote
  # function call in a guard, so the value is inlined here.
  @aad_version_bound 2

  # Compile-time guard: crash the build if @aad_version_bound drifts from
  # Engram.Crypto.row_version_aad_bound/0 (the canonical source of truth).
  unless @aad_version_bound == Engram.Crypto.row_version_aad_bound() do
    raise CompileError,
      description:
        "Engram.Crypto.UserDekRotation @aad_version_bound (#{@aad_version_bound}) " <>
          "drifted from Engram.Crypto.row_version_aad_bound() " <>
          "(#{Engram.Crypto.row_version_aad_bound()})"
  end

  # The tail log is the snapshot's sibling: `CrdtPersistence.update_v1` encrypts
  # every uncheckpointed delta with `Crypto.encrypt_crdt_state/3` under the same
  # DEK and the same NOTE-bound AAD (`replay_tail/3` shapes each row with the
  # note's id to decrypt it). Rewrapping the snapshot without the tail is WORSE
  # than rewrapping neither: `bind/3` then succeeds, `replay_tail/3` drops every
  # undecryptable row with only a warning, the room converges to the stale
  # snapshot, and the next checkpoint materializes it over the body — a loud
  # outage turned into silent loss of every uncheckpointed edit. #1341.
  #
  # A tail row that decrypts under NEITHER dek is left alone rather than raised
  # on: it is one delta, `replay_tail/3` already tolerates dropping it, and
  # raising here would abort a rotation whose earlier batches have committed
  # under a DEK that `final_flip/3` has not yet persisted.
  #
  # One query per BATCH, not per note. A tail row exists only for a note with
  # uncheckpointed deltas, so per-note this is ~50k wasted round trips on a
  # 50k-note vault — every one of them inside the window where the RotationLock
  # is rejecting the user's writes. Covered by the existing
  # [:note_id, :inserted_at] index.
  # DELIBERATELY NOT vault-scoped, unlike every other CrdtUpdateLog read. A DEK
  # is per-USER, so a rotation must rewrap every row that user owns across all
  # their vaults; filtering by vault here would silently leave rows encrypted
  # under the retired key. The `skip_tenant_check: true` below says the same
  # thing. This is the one legitimate exemption from the vault-scoping rule.
  defp rewrap_crdt_tail(batch_ids, old_dek, new_dek) do
    from(l in CrdtUpdateLog, where: l.note_id in ^batch_ids, lock: "FOR UPDATE")
    |> Repo.all(skip_tenant_check: true)
    |> Enum.each(fn row ->
      aad = Crypto.aad_for_row(:notes, :crdt_state, row.note_id)

      case try_rewrap(row.update_ciphertext, row.update_nonce, old_dek, new_dek, aad, aad,
             table: :crdt_update_log,
             phase: :sweep_notes,
             log: "T3.7 sweep_notes: crdt tail row decrypt failed under both old and new DEK",
             log_meta: [row_id: row.id, note_id: row.note_id],
             on_both_failed: {:error, :both_deks_failed}
           ) do
        {:ok, plaintext} ->
          {ct, nonce} = Envelope.encrypt(plaintext, new_dek, aad)

          {1, _} =
            from(l in CrdtUpdateLog, where: l.id == ^row.id)
            |> Repo.update_all(
              [set: [update_ciphertext: ct, update_nonce: nonce]],
              skip_tenant_check: true
            )

          :ok

        # Already under the new DEK (a prior crashed run), or unreadable. Either
        # way there is nothing safe to write. Nothing stamps a version here --
        # the log has no dek_version column; it inherits the note's.
        _ ->
          :ok
      end
    end)
  end

  defp old_aad_for(table, column, %{dek_version: v} = row) when v >= @aad_version_bound,
    do: Crypto.aad_for_row(table, column, row.id)

  defp old_aad_for(_table, _column, _row), do: <<>>

  # Inside the flip's transaction: the points' filter HMACs and sparse
  # vectors are on the retired key from this commit on, so the NULLs the
  # heals select on and the heal jobs commit with it, or not at all. Returns
  # the text guard, which this process cancels once its own text sweep is
  # done (`cancel_text_guard/1`).
  defp hand_points_to_heals(user_id, new_dek_version) do
    {:ok, {_, _}} =
      Repo.with_tenant(user_id, fn ->
        from(n in Engram.Notes.Note, where: n.user_id == ^user_id and n.kind == "note")
        |> Repo.update_all(set: [payload_hash: nil, keyword_version: nil])
      end)

    {:ok, _} = Oban.insert(ReconcileNotePayloads.new(%{"user_id" => user_id}))

    Oban.insert(
      RotationTextGuard.new(
        %{"user_id" => user_id, "dek_version" => new_dek_version},
        schedule_in: RotationTextGuard.delay_seconds()
      )
    )
  end

  defp cancel_text_guard(%Oban.Job{id: id}) when is_integer(id), do: Oban.cancel_job(id)
  defp cancel_text_guard(_conflict), do: :ok

  defp final_flip(%User{} = user, new_dek_version, new_wrapped) do
    # B4: user-vanish treated as structured {:error, ...} — NOT a raise — so it
    # propagates up through the with-chain in run_phases and rotate_user emits
    # telemetry (status=failed) rather than a bare MatchError.
    #
    # I1: DekCache.invalidate is deferred OUTSIDE the Repo.transaction block.
    # If the transaction rolls back (deadlock, advisory-lock contention, etc.),
    # the cache must not be cleared while encrypted_dek is still the old value.
    # Pattern mirrors Crypto.ensure_user_dek/1 (T3.1 race fix, PR #74).
    txn_result =
      Repo.transaction(fn ->
        case from(u in User, where: u.id == ^user.id)
             |> Repo.update_all(
               [
                 set: [
                   encrypted_dek: new_wrapped,
                   dek_version: new_dek_version,
                   dek_rotation_locked_at: nil
                 ]
               ],
               skip_tenant_check: true
             ) do
          {1, _} ->
            {:ok, guard} = hand_points_to_heals(user.id, new_dek_version)
            guard

          {0, _} ->
            Logger.error(
              "T3.7 final_flip: user row vanished mid-rotation",
              Metadata.with_category(:error, :crypto,
                user_id: user.id,
                table: :users,
                row_id: user.id,
                phase: :final_flip
              )
            )

            Repo.rollback({:user_vanished_mid_rotation, user.id})
        end
      end)

    case txn_result do
      {:ok, guard} ->
        # Only invalidate caches after the txn commits successfully. The
        # cached user (which carries `encrypted_dek`) goes FIRST: a DekCache
        # miss between the two would otherwise unwrap the retired blob off it.
        # (Crypto.get_dek/1 also re-reads the blob from the DB on a miss, which
        # covers peers whose :user eviction has not landed yet.)
        Engram.Accounts.evict_user(user.id)
        DekCache.invalidate(user.id)
        {:ok, guard}

      {:error, {:user_vanished_mid_rotation, _uid}} = err ->
        err

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp emit_telemetry(user_id, :ok, duration_us) do
    :telemetry.execute(
      [:engram, :crypto, :rotate, :dek],
      %{duration_us: duration_us, count: 1},
      %{user_id: user_id, status: :ok}
    )
  end

  defp emit_telemetry(user_id, {:error, reason}, duration_us) do
    label = classify_reason(reason)

    Logger.error(
      "T3.7 rotate_user failed user_id=#{user_id} reason_label=#{label}",
      Metadata.with_category(:error, :crypto, user_id: user_id, reason_label: label)
    )

    :telemetry.execute(
      [:engram, :crypto, :rotate, :dek],
      %{duration_us: duration_us, count: 1},
      %{user_id: user_id, status: :failed, reason_label: label}
    )
  end

  defp classify_reason(:not_found), do: "not_found"
  defp classify_reason(:rotation_in_progress), do: "rotation_in_progress"
  defp classify_reason(:invalid_wrapping), do: "invalid_wrapping"
  defp classify_reason(:malformed_wrapped_blob), do: "malformed_wrapped_blob"
  defp classify_reason(:crashed), do: "crashed"
  defp classify_reason({:user_vanished_mid_rotation, _uid}), do: "user_vanished_mid_rotation"
  defp classify_reason({:row_vanished, table, _id, phase}), do: "row_vanished_#{table}_#{phase}"
  defp classify_reason({:qdrant_scroll, _status, _body}), do: "qdrant_scroll_failed"
  defp classify_reason({:qdrant_set_payload_failed, _reason}), do: "qdrant_set_payload_failed"
  defp classify_reason({:qdrant_decrypt_failed, _id, _field}), do: "qdrant_decrypt_failed"

  defp classify_reason(%Postgrex.Error{postgres: %{code: code}}),
    do: "postgres_" <> to_string(code)

  defp classify_reason(%Postgrex.Error{}), do: "postgres_unknown"
  defp classify_reason({status, _body}) when is_integer(status), do: "http_#{status}"
  defp classify_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp classify_reason(%Ecto.Changeset{}), do: "changeset_invalid"

  defp classify_reason(reason) when is_exception(reason),
    do: reason.__struct__ |> Module.split() |> List.last()

  defp classify_reason(_other), do: "other"
end
