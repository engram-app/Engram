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
  alias Engram.Auth.SessionInvalidator
  alias Engram.Crypto
  alias Engram.Crypto.{DekCache, Envelope, MigrationRunner, RotationLock}
  alias Engram.Crypto.KeyProvider.Resolver
  alias Engram.Logger.Metadata
  alias Engram.Notes.CrdtUpdateLog
  alias Engram.Repo
  alias Engram.Vector.Qdrant

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
  # Only the head. `BackfillCrdtState` is deliberately NOT enqueued: its writes
  # would re-fire the same trigger and re-NULL the heads this job just warmed,
  # and seeding is not something a rotation should trigger unsupervised — a note
  # whose real state is an un-checkpointed tail would get a second, unrelated
  # Yjs lineage seeded from content on top of it.
  #
  # Best-effort: a failed enqueue must not fail the rotation.
  defp enqueue_crdt_head_rewarm(user_id) do
    from(v in Engram.Vaults.Vault, where: v.user_id == ^user_id, select: v.id)
    |> Repo.all(skip_tenant_check: true)
    |> Enum.each(fn vault_id ->
      %{"user_id" => user_id, "vault_id" => vault_id}
      |> Engram.Workers.BackfillCrdtHead.new()
      |> Oban.insert()
    end)

    :ok
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
         :ok <- enqueue_crdt_head_rewarm(user_id),
         :ok <- sweep_vaults(user, old_dek, new_dek, new_filter_key, new_dek_version),
         :ok <- sweep_vault_index_states(user, old_dek, new_dek, new_dek_version),
         :ok <- sweep_vault_index_update_log(user, old_dek, new_dek, new_dek_version),
         :ok <- sweep_attachments(user, old_dek, new_dek, new_filter_key, new_dek_version),
         :ok <- sweep_note_links(user, old_dek, new_dek, new_filter_key, new_dek_version),
         :ok <- sweep_qdrant(user, old_dek, new_dek),
         :ok <- final_flip(user, new_dek_version, new_wrapped) do
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
    sweep_table_loop(
      user_id,
      Engram.Notes.Note,
      "00000000-0000-0000-0000-000000000000",
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
    sweep_table_loop(
      user_id,
      Engram.Vaults.Vault,
      "00000000-0000-0000-0000-000000000000",
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

  defp rewrap_vault_columns(
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
            ]

          :already_rotated ->
            # Already rotated under this run's new_dek — skip
            []
        end
      end
    end)
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
    ids =
      from(a in Engram.Attachments.Attachment,
        where: a.user_id == ^user_id and a.id > ^last_id,
        where: is_nil(a.deleted_at),
        order_by: a.id,
        limit: ^@batch_size,
        select: a.id
      )
      |> Repo.all(skip_tenant_check: true)

    case ids do
      [] ->
        :ok

      _ ->
        result =
          Enum.reduce_while(ids, :ok, fn id, :ok ->
            case rotate_one_attachment(id, new_dek_version, old_dek, new_dek, new_filter_key) do
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

  defp rotate_one_attachment(att_id, new_dek_version, old_dek, new_dek, new_filter_key) do
    with {:ok, _} <- mark_pending(att_id, new_dek_version),
         {:ok, attachment, recrypt_result} <-
           recrypt_blob(att_id, old_dek, new_dek, new_dek_version) do
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

  defp mark_pending(att_id, new_dek_version) do
    Repo.transaction(fn ->
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
  defp recrypt_blob(att_id, old_dek, new_dek, new_dek_version) do
    # Storage MatchError fix: use Repo.one/2 + nil case for concurrent hard-delete safety
    attachment =
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
    Repo.transaction(fn ->
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
  # note_links sweep (#591 T7) — same cursor-batch shape as sweep_notes/5.
  # Nullable alias/anchor columns are skipped like notes' description/resource;
  # target_text also carries the basename HMAC used for link resolution.
  # ---------------------------------------------------------------------------

  defp sweep_note_links(%User{id: user_id}, old_dek, new_dek, new_filter_key, new_dek_version) do
    sweep_table_loop(
      user_id,
      Engram.Links.NoteLink,
      "00000000-0000-0000-0000-000000000000",
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
                [{hmac_key, Crypto.hmac_field(new_filter_key, hmac_transform.(plaintext))}]
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

  defp sweep_qdrant(%User{id: user_id}, old_dek, new_dek) do
    collection = Qdrant.collection_name()
    filter = %{must: [%{key: "user_id", match: %{value: user_id}}]}
    sweep_qdrant_loop(collection, filter, user_id, old_dek, new_dek, nil)
  end

  defp sweep_qdrant_loop(collection, filter, user_id, old_dek, new_dek, offset) do
    case Qdrant.scroll(collection,
           filter: filter,
           with_payload: true,
           with_vector: false,
           limit: 200,
           offset: offset
         ) do
      {:ok, %{points: [], next_page_offset: _}} ->
        :ok

      {:ok, %{points: points, next_page_offset: next}} ->
        case rewrap_qdrant_points(collection, user_id, points, old_dek, new_dek) do
          :ok ->
            if is_nil(next) do
              :ok
            else
              sweep_qdrant_loop(collection, filter, user_id, old_dek, new_dek, next)
            end

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

  defp rewrap_qdrant_points(collection, user_id, points, old_dek, new_dek) do
    Enum.reduce_while(points, :ok, fn point, :ok ->
      qdrant_id =
        point["id"] ||
          (
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
          )

      payload = point["payload"] || %{}

      case rewrap_qdrant_payload(collection, qdrant_id, payload, old_dek, new_dek) do
        {:ok, :unchanged} ->
          {:cont, :ok}

        {:ok, new_payload} ->
          case Qdrant.set_payload(collection, [qdrant_id], new_payload) do
            :ok ->
              {:cont, :ok}

            {:error, reason} ->
              Logger.error(
                "T3.7 sweep_qdrant: set_payload failed",
                Metadata.with_category(:error, :crypto,
                  user_id: user_id,
                  qdrant_id: qdrant_id,
                  phase: :sweep_qdrant,
                  status: :set_payload_failed,
                  reason_label: Metadata.safe_reason(reason)
                )
              )

              {:halt, {:error, {:qdrant_set_payload_failed, reason}}}
          end

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  @qdrant_encrypted_fields [:text, :title, :heading_path]

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
      {:ok, _final_payload, false} -> {:ok, :unchanged}
      {:ok, final_payload, true} -> {:ok, final_payload}
      {:error, _} = err -> err
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
    sweep_table_loop(
      user_id,
      Engram.Notes.VaultIndexState,
      "00000000-0000-0000-0000-000000000000",
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
    sweep_table_loop(
      user_id,
      Engram.Notes.VaultIndexUpdateLog,
      "00000000-0000-0000-0000-000000000000",
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

  defp sweep_table_loop(user_id, schema, last_id, fun) do
    ids = fetch_batch_ids(user_id, schema, last_id)

    case ids do
      [] ->
        :ok

      _ ->
        case fun.(ids) do
          :ok -> sweep_table_loop(user_id, schema, List.last(ids), fun)
          {:error, _} = err -> err
        end
    end
  end

  # Notes are scoped via vault.user_id AND directly via user_id; use user_id directly.
  defp fetch_batch_ids(user_id, Engram.Notes.Note, last_id) do
    from(n in Engram.Notes.Note,
      where: n.user_id == ^user_id,
      where: n.id > ^last_id,
      order_by: n.id,
      limit: ^@batch_size,
      select: n.id
    )
    |> Repo.all(skip_tenant_check: true)
  end

  # Keyed by vault_id, not id — the generic clause below orders by `r.id`, which
  # this table does not have.
  defp fetch_batch_ids(user_id, Engram.Notes.VaultIndexState, last_id) do
    from(s in Engram.Notes.VaultIndexState,
      where: s.user_id == ^user_id,
      where: s.vault_id > ^last_id,
      order_by: s.vault_id,
      limit: ^@batch_size,
      select: s.vault_id
    )
    |> Repo.all(skip_tenant_check: true)
  end

  # Default fallback for schemas with a direct user_id column.
  defp fetch_batch_ids(user_id, schema, last_id) do
    from(r in schema,
      where: r.user_id == ^user_id,
      where: r.id > ^last_id,
      order_by: r.id,
      limit: ^@batch_size,
      select: r.id
    )
    |> Repo.all(skip_tenant_check: true)
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
                  ]
                else
                  []
                end

              ct_updates ++ hmac_updates ++ basename_updates

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
          tags = :erlang.binary_to_term(etf_bin, [:safe])
          new_etf = :erlang.term_to_binary(tags)
          {new_ct, new_nonce} = Envelope.encrypt(new_etf, new_dek, new_aad)

          tags_hmac =
            case tags do
              ts when is_list(ts) -> Enum.map(ts, &Crypto.hmac_field(new_filter_key, &1))
              _ -> []
            end

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
            :ok

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
      {:ok, :ok} ->
        # Only invalidate cache after the txn commits successfully.
        DekCache.invalidate(user.id)
        :ok

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
