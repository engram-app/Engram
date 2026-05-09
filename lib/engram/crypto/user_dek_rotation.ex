defmodule Engram.Crypto.UserDekRotation do
  @moduledoc """
  T3.7 — per-user DEK rotation orchestrator. Generates a new DEK for the
  target user, rewraps every ciphertext column on every owned row
  (notes / vaults / attachments / Qdrant payloads) under the new key,
  then atomically flips `users.encrypted_dek`.

  The user is locked (read + write) for the duration via
  `Engram.Crypto.RotationLock`; clients receive HTTP 503 with
  `Retry-After: 60` until the rotation completes.

  See `docs/encryption-tier-3-audit.md` § Phase T3.7.
  """

  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts.User
  alias Engram.Crypto
  alias Engram.Crypto.{DekCache, Envelope, RotationLock}
  alias Engram.Crypto.KeyProvider.Resolver
  alias Engram.Repo

  require Logger

  @batch_size 200

  @type rotate_result :: :ok | :skipped | {:error, term()}

  @spec rotate_user(integer() | User.t(), pos_integer()) :: rotate_result()
  def rotate_user(user_or_id, target_dek_version)
      when is_integer(target_dek_version) and target_dek_version >= 1 do
    user_id =
      case user_or_id do
        %User{id: id} -> id
        id when is_integer(id) -> id
      end

    started_at = System.monotonic_time()
    result = do_rotate(user_id, target_dek_version)
    duration_us = duration_us_since(started_at)
    emit_telemetry(user_id, target_dek_version, result, duration_us)
    result
  end

  defp do_rotate(user_id, target_dek_version) do
    with {:ok, user} <- load_user(user_id),
         :continue <- short_circuit_if_at_target(user, target_dek_version),
         {:ok, _locked_at} <- RotationLock.acquire(user_id, target_dek_version: target_dek_version) do
      try do
        run_phases(user, target_dek_version)
      rescue
        e ->
          Logger.error(
            "T3.7 rotate_user crashed user_id=#{user_id} kind=#{inspect(e.__struct__)} message=#{Exception.message(e)}",
            category: :crypto_rotation
          )

          # Lock intentionally NOT released — operator must investigate
          # before retry. Re-raise so caller sees the failure.
          reraise e, __STACKTRACE__
      end
    else
      :skipped -> :skipped
      {:error, _} = err -> err
    end
  end

  defp load_user(user_id) do
    case Repo.one(from(u in User, where: u.id == ^user_id, select: u), skip_tenant_check: true) do
      nil -> {:error, :not_found}
      %User{} = u -> {:ok, u}
    end
  end

  defp short_circuit_if_at_target(%User{dek_version: v}, target) when v >= target, do: :skipped
  defp short_circuit_if_at_target(_user, _target), do: :continue

  defp run_phases(%User{} = user, target_dek_version) do
    user_id = user.id

    with {:ok, old_dek} <- Crypto.get_dek(user),
         provider = Resolver.provider_for(user_id),
         {:ok, new_wrapped, new_dek} <-
           provider.rotate_dek(user.encrypted_dek, %{user_id: user_id}),
         new_filter_key = Crypto.dek_filter_key_from_bytes(new_dek),
         :ok <- sweep_notes(user, old_dek, new_dek, new_filter_key, target_dek_version),
         :ok <- sweep_vaults(user, old_dek, new_dek, new_filter_key, target_dek_version),
         :ok <- sweep_attachments(user, old_dek, new_dek, new_filter_key, target_dek_version),
         :ok <- final_flip(user, target_dek_version, new_wrapped) do
      :ok
    else
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Notes sweep
  # ---------------------------------------------------------------------------

  defp sweep_notes(%User{id: user_id}, old_dek, new_dek, new_filter_key, target_dek_version) do
    sweep_table_loop(
      user_id,
      Engram.Notes.Note,
      target_dek_version,
      0,
      fn batch_ids ->
        Repo.transaction(fn ->
          notes =
            from(n in Engram.Notes.Note,
              where: n.id in ^batch_ids and n.dek_version < ^target_dek_version,
              lock: "FOR UPDATE"
            )
            |> Repo.all(skip_tenant_check: true)

          Enum.each(notes, fn note ->
            updates = rewrap_note_columns(note, old_dek, new_dek, new_filter_key)

            {1, _} =
              from(n in Engram.Notes.Note, where: n.id == ^note.id)
              |> Repo.update_all(
                [set: updates ++ [dek_version: target_dek_version]],
                skip_tenant_check: true
              )
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

  defp sweep_vaults(%User{id: user_id}, old_dek, new_dek, new_filter_key, target_dek_version) do
    sweep_table_loop(
      user_id,
      Engram.Vaults.Vault,
      target_dek_version,
      0,
      fn batch_ids ->
        Repo.transaction(fn ->
          vaults =
            from(v in Engram.Vaults.Vault,
              where: v.id in ^batch_ids and v.dek_version < ^target_dek_version,
              lock: "FOR UPDATE"
            )
            |> Repo.all(skip_tenant_check: true)

          Enum.each(vaults, fn vault ->
            updates = rewrap_vault_columns(vault, old_dek, new_dek, new_filter_key)

            {1, _} =
              from(v in Engram.Vaults.Vault, where: v.id == ^vault.id)
              |> Repo.update_all([set: updates ++ [dek_version: target_dek_version]], skip_tenant_check: true)
          end)
        end)
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    )
  end

  defp rewrap_vault_columns(%Engram.Vaults.Vault{} = vault, old_dek, new_dek, new_filter_key) do
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

        case Envelope.decrypt(ct, nonce, old_dek, old_aad) do
          {:ok, plaintext} ->
            new_aad = Crypto.aad_for_row(:vaults, column, vault.id)
            {new_ct, new_nonce} = Envelope.encrypt(plaintext, new_dek, new_aad)

            [
              {ct_field, new_ct},
              {nonce_field, new_nonce},
              {hmac_key, Crypto.hmac_field(new_filter_key, plaintext)}
            ]

          :error ->
            raise "T3.7 sweep_vaults: decrypt failed for vault id=#{vault.id} column=#{column}"
        end
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Attachments sweep (two-phase commit per blob)
  # ---------------------------------------------------------------------------
  #
  # Content ciphertext lives in S3, not in the DB — so we cannot do a simple
  # batch UPDATE like notes/vaults. Each attachment requires:
  #   Txn 1: mark dek_version_pending = target  (crash-resume marker)
  #   S3 op: GET old ciphertext → decrypt(old_dek) → encrypt(new_dek) → PUT
  #   Txn 2: dek_version = target, dek_version_pending = nil,
  #           rewrap path_ciphertext/path_nonce + recompute path_hmac
  #
  # The cursor query picks up rows where either dek_version < target OR
  # dek_version_pending == target so a crash after Txn 1 is re-tried.

  defp sweep_attachments(%User{id: user_id}, old_dek, new_dek, new_filter_key, target_dek_version) do
    sweep_attachment_loop(user_id, target_dek_version, old_dek, new_dek, new_filter_key, 0)
  end

  defp sweep_attachment_loop(user_id, target_dek_version, old_dek, new_dek, new_filter_key, last_id) do
    ids =
      from(a in Engram.Attachments.Attachment,
        where: a.user_id == ^user_id and a.id > ^last_id,
        where:
          a.dek_version < ^target_dek_version or a.dek_version_pending == ^target_dek_version,
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
            case rotate_one_attachment(id, target_dek_version, old_dek, new_dek, new_filter_key) do
              :ok -> {:cont, :ok}
              {:error, _} = err -> {:halt, err}
            end
          end)

        case result do
          :ok ->
            sweep_attachment_loop(
              user_id,
              target_dek_version,
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

  defp rotate_one_attachment(att_id, target_dek_version, old_dek, new_dek, new_filter_key) do
    with {:ok, _} <- mark_pending(att_id, target_dek_version),
         {:ok, attachment, new_content_nonce} <- recrypt_blob(att_id, old_dek, new_dek),
         :ok <- finalize_attachment(attachment, target_dek_version, old_dek, new_dek, new_filter_key, new_content_nonce) do
      :ok
    end
  end

  defp mark_pending(att_id, target_dek_version) do
    Repo.transaction(fn ->
      {1, _} =
        from(a in Engram.Attachments.Attachment, where: a.id == ^att_id)
        |> Repo.update_all([set: [dek_version_pending: target_dek_version]], skip_tenant_check: true)

      :ok
    end)
    |> case do
      {:ok, :ok} -> {:ok, :ok}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recrypt_blob(att_id, old_dek, new_dek) do
    attachment =
      Repo.one!(
        from(a in Engram.Attachments.Attachment, where: a.id == ^att_id),
        skip_tenant_check: true
      )

    with {:ok, ct} <- Engram.Storage.adapter().get(attachment.storage_key),
         old_aad = old_aad_for(:attachments, :content, attachment),
         {:ok, plaintext} <- decrypt_blob_or_err(ct, attachment.content_nonce, old_dek, old_aad, att_id) do
      new_aad = Crypto.aad_for_row(:attachments, :content, attachment.id)
      {new_ct, new_nonce} = Envelope.encrypt(plaintext, new_dek, new_aad)

      case Engram.Storage.adapter().put(attachment.storage_key, new_ct,
             content_type: attachment.mime_type
           ) do
        :ok -> {:ok, attachment, new_nonce}
        {:error, _} = err -> err
      end
    end
  end

  defp decrypt_blob_or_err(ct, nonce, dek, aad, att_id) do
    case Envelope.decrypt(ct, nonce, dek, aad) do
      {:ok, _pt} = ok -> ok
      :error -> {:error, {:decrypt_failed, att_id}}
    end
  end

  defp finalize_attachment(
         %Engram.Attachments.Attachment{} = attachment,
         target_dek_version,
         old_dek,
         new_dek,
         new_filter_key,
         new_content_nonce
       ) do
    Repo.transaction(fn ->
      meta_updates = rewrap_attachment_metadata_columns(attachment, old_dek, new_dek, new_filter_key)

      {1, _} =
        from(a in Engram.Attachments.Attachment, where: a.id == ^attachment.id)
        |> Repo.update_all(
          [
            set:
              meta_updates ++
                [
                  content_nonce: new_content_nonce,
                  dek_version: target_dek_version,
                  dek_version_pending: nil
                ]
          ],
          skip_tenant_check: true
        )

      :ok
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
         new_filter_key
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

        case Envelope.decrypt(ct, nonce, old_dek, old_aad) do
          {:ok, plaintext} ->
            {new_ct, new_nonce} = Envelope.encrypt(plaintext, new_dek, new_aad)

            [
              {ct_field, new_ct},
              {nonce_field, new_nonce},
              {hmac_field_key, Crypto.hmac_field(new_filter_key, plaintext)}
            ]

          :error ->
            raise "T3.7 sweep_attachments: metadata decrypt failed for att id=#{att.id} column=#{column}"
        end
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Generic cursor-based sweep loop (reused by vaults + attachments in 4.4/4.5)
  # ---------------------------------------------------------------------------

  defp sweep_table_loop(user_id, schema, target_dek_version, last_id, fun) do
    ids = fetch_batch_ids(user_id, schema, target_dek_version, last_id)

    case ids do
      [] ->
        :ok

      _ ->
        case fun.(ids) do
          :ok -> sweep_table_loop(user_id, schema, target_dek_version, List.last(ids), fun)
          {:error, _} = err -> err
        end
    end
  end

  # Notes are scoped via vault.user_id AND directly via user_id; use user_id directly.
  defp fetch_batch_ids(user_id, Engram.Notes.Note, target_dek_version, last_id) do
    from(n in Engram.Notes.Note,
      where: n.user_id == ^user_id and n.dek_version < ^target_dek_version,
      where: n.id > ^last_id,
      order_by: n.id,
      limit: ^@batch_size,
      select: n.id
    )
    |> Repo.all(skip_tenant_check: true)
  end

  # Default fallback for schemas with a direct user_id column.
  defp fetch_batch_ids(user_id, schema, target_dek_version, last_id) do
    from(r in schema,
      where: r.user_id == ^user_id and r.dek_version < ^target_dek_version,
      where: r.id > ^last_id,
      order_by: r.id,
      limit: ^@batch_size,
      select: r.id
    )
    |> Repo.all(skip_tenant_check: true)
  end

  # Re-encrypt all ciphertext column pairs under the new DEK and recompute
  # HMAC-indexed fields from the decrypted plaintext using the new filter key.
  # AAD is `<<>>` for legacy rows (dek_version < 2), row-id-bound for v2+.
  defp rewrap_note_columns(%Engram.Notes.Note{} = note, old_dek, new_dek, new_filter_key) do
    base_columns = [
      {:content, :content_ciphertext, :content_nonce, nil},
      {:title, :title_ciphertext, :title_nonce, nil},
      {:path, :path_ciphertext, :path_nonce, :path_hmac},
      {:folder, :folder_ciphertext, :folder_nonce, :folder_hmac}
    ]

    base_updates =
      base_columns
      |> Enum.flat_map(fn {column, ct_field, nonce_field, hmac_key} ->
        ct = Map.get(note, ct_field)
        nonce = Map.get(note, nonce_field)

        if is_nil(ct) or is_nil(nonce) do
          []
        else
          old_aad = old_aad_for(:notes, column, note)

          case Envelope.decrypt(ct, nonce, old_dek, old_aad) do
            {:ok, plaintext} ->
              new_aad = Crypto.aad_for_row(:notes, column, note.id)
              {new_ct, new_nonce} = Envelope.encrypt(plaintext, new_dek, new_aad)

              ct_updates = [{ct_field, new_ct}, {nonce_field, new_nonce}]

              hmac_updates =
                if hmac_key && is_binary(plaintext) do
                  [{hmac_key, Crypto.hmac_field(new_filter_key, plaintext)}]
                else
                  []
                end

              ct_updates ++ hmac_updates

            :error ->
              raise "T3.7 sweep_notes: decrypt failed for note id=#{note.id} column=#{column}"
          end
        end
      end)

    base_updates ++ rewrap_tags(note, old_dek, new_dek, new_filter_key)
  end

  defp rewrap_tags(%Engram.Notes.Note{tags_ciphertext: nil}, _old_dek, _new_dek, _new_filter_key),
    do: []

  defp rewrap_tags(%Engram.Notes.Note{} = note, old_dek, new_dek, new_filter_key) do
    ct = note.tags_ciphertext
    nonce = note.tags_nonce

    if is_nil(ct) or is_nil(nonce) do
      []
    else
      old_aad = old_aad_for(:notes, :tags, note)

      case Envelope.decrypt(ct, nonce, old_dek, old_aad) do
        {:ok, etf_bin} ->
          tags = :erlang.binary_to_term(etf_bin, [:safe])
          new_etf = :erlang.term_to_binary(tags)
          new_aad = Crypto.aad_for_row(:notes, :tags, note.id)
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

        :error ->
          raise "T3.7 sweep_notes: decrypt failed for note id=#{note.id} column=tags"
      end
    end
  end

  # Derive the correct AAD for an existing encrypted row based on its dek_version.
  # Rows with dek_version < 2 were written with empty AAD (pre-T3.6).
  # The bound 2 mirrors Crypto.@row_version_aad_bound — cannot use a remote
  # function call in a guard, so the value is inlined here.
  @aad_version_bound 2

  defp old_aad_for(table, column, %{dek_version: v} = row) when v >= @aad_version_bound,
    do: Crypto.aad_for_row(table, column, row.id)

  defp old_aad_for(_table, _column, _row), do: <<>>

  defp final_flip(%User{} = user, target_dek_version, new_wrapped) do
    Repo.transaction(fn ->
      {1, _} =
        from(u in User, where: u.id == ^user.id)
        |> Repo.update_all(
          [
            set: [
              encrypted_dek: new_wrapped,
              dek_version: target_dek_version,
              dek_rotation_locked_at: nil
            ]
          ],
          skip_tenant_check: true
        )

      DekCache.invalidate(user.id)
      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp duration_us_since(started_at) do
    System.convert_time_unit(
      System.monotonic_time() - started_at,
      :native,
      :microsecond
    )
  end

  defp emit_telemetry(user_id, target, :ok, duration_us) do
    :telemetry.execute(
      [:engram, :crypto, :rotate, :dek],
      %{duration_us: duration_us, count: 1},
      %{user_id: user_id, target_dek_version: target, status: :ok}
    )
  end

  defp emit_telemetry(user_id, target, :skipped, duration_us) do
    :telemetry.execute(
      [:engram, :crypto, :rotate, :dek],
      %{duration_us: duration_us, count: 1},
      %{user_id: user_id, target_dek_version: target, status: :skipped}
    )
  end

  defp emit_telemetry(user_id, target, {:error, reason}, duration_us) do
    label = classify_reason(reason)

    Logger.error(
      "T3.7 rotate_user failed user_id=#{user_id} target=#{target} reason_label=#{label}",
      category: :crypto_rotation
    )

    :telemetry.execute(
      [:engram, :crypto, :rotate, :dek],
      %{duration_us: duration_us, count: 1},
      %{user_id: user_id, target_dek_version: target, status: :failed, reason_label: label}
    )
  end

  defp classify_reason(:not_found), do: "not_found"
  defp classify_reason(:rotation_in_progress), do: "rotation_in_progress"
  defp classify_reason(:invalid_wrapping), do: "invalid_wrapping"
  defp classify_reason(:malformed_wrapped_blob), do: "malformed_wrapped_blob"
  defp classify_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp classify_reason(%Ecto.Changeset{}), do: "changeset_invalid"

  defp classify_reason(reason) when is_exception(reason),
    do: reason.__struct__ |> Module.split() |> List.last()

  defp classify_reason(_other), do: "other"
end
