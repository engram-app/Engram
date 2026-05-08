defmodule Engram.Crypto.AadRebind do
  @moduledoc """
  T3.6 / H1 — per-user AAD-rebind backfill.

  For each user, walks `notes`, `attachments`, and `vaults` rows with
  `dek_version < target_version` (default 2). For each legacy row:

    1. Decrypts every ciphertext column with empty AAD (legacy semantics).
    2. Re-encrypts with row-id-bound AAD
       (`"<table>:<column>:<row_id>"`).
    3. Stamps `dek_version = target_version` on the row in a single
       UPDATE so the read path's AAD dispatch flips atomically.

  Also upgrades the user's `encrypted_dek` wrap format from v1 (or pre-T3.4
  legacy) to v2 (AAD-bound, AAD = `"dek:v1:<user_id>"`) if it is not
  already.

  Per-user transaction with `SELECT ... FOR UPDATE` on the user row.
  Concurrent runs serialize cleanly: the loser sees an already-rebound
  user and short-circuits to `:skipped`.

  ## When to use

  Only relevant during the T3.6 cutover. After the backfill drains
  (`SELECT MIN(dek_version) FROM notes ≥ 2` and ditto for attachments /
  vaults / users), every read path uses constructed AAD and the empty-AAD
  fallback in the decrypt helpers becomes dead code (kept anyway as a
  safety net).
  """

  import Ecto.Query
  require Logger

  alias Engram.Accounts.User
  alias Engram.Attachments.Attachment
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Crypto.KeyProvider.Resolver
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults.Vault

  @typedoc "`:ok` on rebind, `:skipped` on no-op, `{:error, reason}` on failure."
  @type rebind_result :: :ok | :skipped | {:error, term()}

  @typedoc "Aggregate over the user fleet."
  @type counts :: %{
          ok: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer()
        }

  @target_version 2

  @doc "Rebind all users with at least one row below target."
  @spec rebind_all(keyword()) :: counts()
  def rebind_all(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 100)
    drive_loop(0, batch_size, %{ok: 0, skipped: 0, failed: 0})
  end

  @doc "Rebind a single user. Idempotent — already-rebound users return `:skipped`."
  @spec rebind_user(integer() | User.t()) :: rebind_result()
  def rebind_user(%User{id: id}), do: rebind_user(id)

  def rebind_user(user_id) when is_integer(user_id) do
    started_at = System.monotonic_time()
    result = do_rebind(user_id)
    duration_us = duration_us_since(started_at)
    emit_telemetry(user_id, result, duration_us)

    case result do
      {:rebound, _} -> :ok
      :skipped -> :skipped
      {:error, reason} -> {:error, reason}
    end
  end

  # ── internals ───────────────────────────────────────────────────────────────

  defp do_rebind(user_id) do
    Repo.transaction(fn ->
      locked =
        from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE")
        |> Repo.one(skip_tenant_check: true)

      cond do
        is_nil(locked) ->
          Repo.rollback({:not_found, user_id})

        is_nil(locked.encrypted_dek) ->
          # Provisioned-on-demand user — nothing to rebind.
          :skipped

        true ->
          rebind_locked_user(locked)
      end
    end)
    |> case do
      {:ok, :skipped} -> :skipped
      {:ok, {:rebound, _} = ok} -> ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp rebind_locked_user(%User{} = user) do
    # T3-audit M3 — track whether anything was actually changed so re-runs
    # of an already-rebound user return :skipped (not :ok). Operator drain
    # logs can then distinguish real work from no-ops.
    #
    # T3-audit H5 — `rebind_user_attachments/1` is intentionally a no-op
    # (S3 blobs converge on next upload). We invoke it separately so the
    # `with` chain only depends on rebinds that touch ciphertext, and
    # surface the legacy attachment count via telemetry so an operator
    # drain log isn't silently misleading.
    with {:ok, dek_changed?} <- rewrap_user_dek_if_needed(user),
         {:ok, notes_count} <- rebind_user_notes(user),
         {:ok, vaults_count} <- rebind_user_vaults(user) do
      _ = rebind_user_attachments(user)

      if dek_changed? or notes_count > 0 or vaults_count > 0 do
        {:rebound, user}
      else
        :skipped
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # 0x01 (or pre-T3.4 60-byte legacy) → 0x02 with AAD = "dek:v1:<user_id>".
  # Returns {:ok, true} if the wrap was upgraded, {:ok, false} if it was
  # already v2 (no-op), or {:error, _} on failure.
  defp rewrap_user_dek_if_needed(%User{encrypted_dek: blob} = user) do
    case classify_wrap(blob) do
      :v2 ->
        {:ok, false}

      :legacy_or_v1 ->
        provider = Resolver.provider_for(user.id)
        ctx = %{user_id: user.id}

        with {:ok, dek} <- provider.unwrap_dek(blob, ctx),
             {:ok, new_wrapped} <- provider.wrap_dek(dek, ctx) do
          changeset = Ecto.Changeset.change(user, encrypted_dek: new_wrapped)

          case Repo.update(changeset, skip_tenant_check: true) do
            {:ok, _} ->
              # Invalidate any cached plaintext DEK keyed off the previous
              # wrap so the next get_dek/1 re-derives via the new wrap. The
              # plaintext DEK material is unchanged; only the wrap envelope
              # changed.
              Crypto.DekCache.invalidate(user.id)
              {:ok, true}

            {:error, changeset} ->
              {:error, changeset}
          end
        end
    end
  end

  defp classify_wrap(<<0x02, 0x01, _rest::binary>>), do: :v2
  defp classify_wrap(_blob), do: :legacy_or_v1

  # Returns {:ok, count_rebound} or {:error, reason}. Count drives M3
  # idempotency — zero rebinds + no DEK rewrap = :skipped.
  defp rebind_user_notes(%User{id: user_id} = user) do
    {:ok, dek} = Crypto.get_dek(user)
    legacy_version = Crypto.row_version_legacy()

    rows =
      from(n in Note,
        where: n.user_id == ^user_id and n.dek_version == ^legacy_version,
        select: n
      )
      |> Repo.all(skip_tenant_check: true)

    Enum.reduce_while(rows, {:ok, 0}, fn note, {:ok, n} ->
      case rebind_note(note, dek) do
        :ok -> {:cont, {:ok, n + 1}}
        {:error, reason} -> {:halt, {:error, {:note, note.id, reason}}}
      end
    end)
  end

  defp rebind_note(%Note{id: id} = note, dek) do
    with {:ok, content} <- decrypt_legacy(note.content_ciphertext, note.content_nonce, dek),
         {:ok, title} <- decrypt_legacy(note.title_ciphertext, note.title_nonce, dek),
         {:ok, path} <- decrypt_legacy(note.path_ciphertext, note.path_nonce, dek),
         {:ok, folder} <- decrypt_legacy(note.folder_ciphertext, note.folder_nonce, dek),
         {:ok, tags_bin} <- decrypt_legacy(note.tags_ciphertext, note.tags_nonce, dek) do
      {content_ct, content_n} =
        Envelope.encrypt(content, dek, Crypto.aad_for_row(:notes, :content, id))

      {title_ct, title_n} =
        Envelope.encrypt(title, dek, Crypto.aad_for_row(:notes, :title, id))

      {path_ct, path_n} =
        Envelope.encrypt(path, dek, Crypto.aad_for_row(:notes, :path, id))

      {folder_ct, folder_n} =
        Envelope.encrypt(folder, dek, Crypto.aad_for_row(:notes, :folder, id))

      {tags_ct, tags_n} =
        Envelope.encrypt(tags_bin, dek, Crypto.aad_for_row(:notes, :tags, id))

      {1, _} =
        from(n in Note, where: n.id == ^id)
        |> Repo.update_all(
          [
            set: [
              content_ciphertext: content_ct,
              content_nonce: content_n,
              title_ciphertext: title_ct,
              title_nonce: title_n,
              path_ciphertext: path_ct,
              path_nonce: path_n,
              folder_ciphertext: folder_ct,
              folder_nonce: folder_n,
              tags_ciphertext: tags_ct,
              tags_nonce: tags_n,
              dek_version: @target_version
            ]
          ],
          skip_tenant_check: true
        )

      :ok
    end
  end

  # T3-audit H5 — attachment rebind is intentional no-op (see comment on
  # rebind_attachment/2). Counts legacy attachments and emits per-user
  # telemetry + Logger so the operator drain log is honest about what was
  # NOT rebound. Returns {:skipped, :not_supported, count}.
  defp rebind_user_attachments(%User{id: user_id} = _user) do
    legacy_version = Crypto.row_version_legacy()

    legacy_count =
      from(a in Attachment,
        where: a.user_id == ^user_id and a.dek_version == ^legacy_version,
        select: count(a.id)
      )
      |> Repo.one(skip_tenant_check: true)
      |> case do
        nil -> 0
        n when is_integer(n) -> n
      end

    :telemetry.execute(
      [:engram, :crypto, :aad_rebind, :attachment_skipped],
      %{count: legacy_count},
      %{user_id: user_id}
    )

    if legacy_count > 0 do
      Logger.info(
        "aad rebind attachment skipped (intentional) user_id=#{user_id} legacy_count=#{legacy_count} note=converges on next upload",
        category: :crypto_rebind
      )
    end

    {:skipped, :not_supported, legacy_count}
  end

  # NOTE: attachments hold their content blob in S3, not in Postgres.
  # The S3 object's content_ciphertext keeps its old AAD (=<<>>) until
  # the blob is rotated through `Storage.adapter`. The read path uses
  # `att.dek_version` to gate the AAD on path + content decrypt. Rebinding
  # only the row-resident `path_ciphertext` would mismatch the S3 blob's
  # AAD on next read, so we deliberately skip the rebind. Attachments
  # converge naturally on their next write — every `upsert_attachment`
  # re-encrypts content + path with v2 AAD. Old blobs that are never
  # re-uploaded stay legacy forever, which is fine because their content
  # was always written with empty AAD and the read path honors that via
  # `att.dek_version`.
  #
  # T3-audit H5 — `rebind_user_attachments/1` surfaces the count of
  # unconverged attachments per user via
  # `[:engram, :crypto, :aad_rebind, :attachment_skipped]` telemetry so
  # operator drain logs are honest about what was NOT rebound.

  # Returns {:ok, count_rebound} or {:error, reason}.
  defp rebind_user_vaults(%User{id: user_id} = user) do
    {:ok, dek} = Crypto.get_dek(user)
    legacy_version = Crypto.row_version_legacy()

    rows =
      from(v in Vault,
        where: v.user_id == ^user_id and v.dek_version == ^legacy_version,
        select: v
      )
      |> Repo.all(skip_tenant_check: true)

    Enum.reduce_while(rows, {:ok, 0}, fn vault, {:ok, n} ->
      case rebind_vault(vault, dek) do
        :ok -> {:cont, {:ok, n + 1}}
        {:error, reason} -> {:halt, {:error, {:vault, vault.id, reason}}}
      end
    end)
  end

  defp rebind_vault(%Vault{id: id} = vault, dek) do
    with {:ok, name} <- decrypt_legacy(vault.name_ciphertext, vault.name_nonce, dek) do
      {ct, n} = Envelope.encrypt(name, dek, Crypto.aad_for_row(:vaults, :name, id))

      {1, _} =
        from(v in Vault, where: v.id == ^id)
        |> Repo.update_all(
          [
            set: [
              name_ciphertext: ct,
              name_nonce: n,
              dek_version: @target_version
            ]
          ],
          skip_tenant_check: true
        )

      :ok
    end
  end

  defp decrypt_legacy(nil, _nonce, _dek), do: {:ok, nil}
  defp decrypt_legacy(_ct, nil, _dek), do: {:ok, nil}

  defp decrypt_legacy(ct, nonce, dek) do
    case Envelope.decrypt(ct, nonce, dek, <<>>) do
      {:ok, plaintext} -> {:ok, plaintext}
      :error -> {:error, :legacy_decrypt_failed}
    end
  end

  defp drive_loop(last_id, batch_size, acc) do
    ids =
      from(u in User,
        where: not is_nil(u.encrypted_dek) and u.id > ^last_id,
        select: u.id,
        order_by: u.id,
        limit: ^batch_size
      )
      |> Repo.all(skip_tenant_check: true)

    case ids do
      [] ->
        acc

      _ ->
        acc =
          Enum.reduce(ids, acc, fn id, a ->
            case rebind_user(id) do
              :ok -> Map.update!(a, :ok, &(&1 + 1))
              :skipped -> Map.update!(a, :skipped, &(&1 + 1))
              {:error, _} -> Map.update!(a, :failed, &(&1 + 1))
            end
          end)

        drive_loop(List.last(ids), batch_size, acc)
    end
  end

  defp duration_us_since(started_at) do
    System.convert_time_unit(
      System.monotonic_time() - started_at,
      :native,
      :microsecond
    )
  end

  defp emit_telemetry(user_id, {:rebound, _}, duration_us) do
    :telemetry.execute(
      [:engram, :crypto, :aad_rebind, :user],
      %{duration_us: duration_us, count: 1},
      %{user_id: user_id, status: :ok}
    )
  end

  defp emit_telemetry(user_id, :skipped, duration_us) do
    :telemetry.execute(
      [:engram, :crypto, :aad_rebind, :user],
      %{duration_us: duration_us, count: 1},
      %{user_id: user_id, status: :skipped}
    )
  end

  defp emit_telemetry(user_id, {:error, reason}, duration_us) do
    label = reason_label(reason)

    # T3-audit H4 — telemetry alone leaves operators without per-user
    # triage during a backfill drain. Logger.error surfaces the user_id +
    # reason_label in any standard log pipeline so a stuck rebind is
    # diagnosable, not just countable.
    Logger.error(
      "aad rebind failed user_id=#{user_id} reason_label=#{label}",
      category: :crypto_rebind
    )

    :telemetry.execute(
      [:engram, :crypto, :aad_rebind, :user],
      %{duration_us: duration_us, count: 1},
      %{user_id: user_id, status: :failed, reason_label: label}
    )
  end

  defp reason_label({:not_found, _}), do: "not_found"
  defp reason_label({:note, _, r}), do: "note:" <> reason_label(r)
  defp reason_label({:vault, _, r}), do: "vault:" <> reason_label(r)
  defp reason_label({:attachment, _, r}), do: "attachment:" <> reason_label(r)
  defp reason_label(:legacy_decrypt_failed), do: "legacy_decrypt_failed"
  defp reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_label(_), do: "other"
end
