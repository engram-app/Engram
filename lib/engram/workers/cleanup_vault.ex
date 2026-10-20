defmodule Engram.Workers.CleanupVault do
  @moduledoc """
  Oban worker: hard-deletes all data for a soft-deleted vault after the retention period.

  Scheduled 30 days after soft-delete. If the vault has been restored (deleted_at cleared)
  or doesn't exist, the job is a no-op.

  Cleanup order:
  1. Qdrant points (best-effort, non-fatal)
  2. Stamp `purge_started_at`: from here `Vaults.restore_vault/2` refuses the
     vault, since a purge that fails part-way leaves it partial
  3. Chunks, then notes, then attachments in id-ordered batches, each its own
     transaction (attachment blobs deleted after each batch commits)
  4. One transaction for the remainder: chunks, notes, attachments, keys,
     grants, api_key_vaults, the vault row
  5. Remaining storage blobs (post-commit, best-effort), only after the DB is
     authoritative, chunked upload sessions included (open multipart uploads
     aborted)
  """

  # Deliberately NO Oban `unique` key: a restore-then-re-delete cycle needs a
  # second scheduled job while the first (now no-op) one still exists, and
  # uniqueness over :scheduled would silently drop it — losing the cleanup.
  # Duplicate-run safety comes from the DB transaction instead: the second
  # run's `Repo.delete!` hits StaleEntryError on the vanished row and rolls
  # back (same reasoning documented in BackfillCrdtHead/BackfillCrdtState).
  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  alias Engram.Accounts.ApiKey
  alias Engram.Attachments.Attachment
  alias Engram.Attachments.Upload
  alias Engram.Logger.Metadata
  alias Engram.Notes.{Chunk, Note}
  alias Engram.Permissions
  alias Engram.Repo
  alias Engram.UsageMeters
  alias Engram.Vaults.Vault

  require Logger

  @retention_days 30
  @retention_secs @retention_days * 86_400

  # 60 min, the Lifeline `rescue_after` ceiling. This walks every row it
  # owns, and none of the long queues (crypto_backfill/export/cleanup) is
  # user-facing — a slot held here costs nothing, while a kill mid-rotation
  # costs a lot. Finite is the point, not tight. See #1496.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(60)

  @doc """
  Enqueues a CleanupVault job scheduled 30 days from now.
  """
  def enqueue(vault_id, user_id) do
    %{vault_id: vault_id, user_id: user_id}
    |> new(scheduled_at: DateTime.add(DateTime.utc_now(), @retention_days, :day))
    |> Oban.insert()
  end

  @doc """
  Enqueues an immediate (unscheduled) force-purge. Used by the "delete
  permanently now" path — bypasses the retention age guard.
  """
  def enqueue_now(vault_id, user_id) do
    %{vault_id: vault_id, user_id: user_id, force: true}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"vault_id" => vault_id, "user_id" => user_id} = args}) do
    perform_cleanup(vault_id, user_id, force: Map.get(args, "force", false))
  end

  @doc false
  def perform_cleanup(vault_id, user_id, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    # Tenant-scoped, and this load is the linchpin. Unscoped it was FILTERED to
    # nil rather than rejected, and the `is_nil(vault)` clause below reads nil
    # as "already cleaned up" — so the job logged at :debug, returned `:ok`,
    # and deleted nothing. Every observable said the cleanup ran while the
    # user's data survived.
    vault = Repo.with_tenant!(user_id, fn -> Repo.get(Vault, vault_id) end)

    # A scoped load cannot return another tenant's vault, so `nil` is now
    # ambiguous: the vault may be genuinely gone, or it may exist and belong to
    # someone else (forged args, or crossed wires). Those deserve very
    # different reactions — one is routine, the other is a security event — so
    # the ambiguity is resolved rather than collapsed into "skipping".
    foreign_owner_id = if is_nil(vault), do: foreign_owner(vault_id, user_id)

    cond do
      # Defense in depth, and the reason the scoped load did not simply delete
      # this branch. Never hard-delete another tenant's vault.
      #
      # Honest limitation, now narrowed: the probe runs on `Repo.maintenance()`,
      # so it answers correctly wherever a maintenance pool is configured. Only
      # with RLS enforced AND no maintenance pool is a forged job
      # indistinguishable from a deleted vault, falling through to the `:ok`
      # branch. It refuses to delete either way — it just cannot say why.
      not is_nil(foreign_owner_id) ->
        Logger.error(
          "CleanupVault: owner mismatch — discarding",
          Metadata.with_category(:error, :oban,
            vault_id: vault_id,
            user_id: user_id,
            reason_label: :owner_mismatch
          )
        )

        {:discard, :owner_mismatch}

      is_nil(vault) ->
        Logger.debug(
          "CleanupVault: vault not found — skipping",
          Metadata.with_category(:debug, :oban, vault_id: vault_id)
        )

        :ok

      is_nil(vault.deleted_at) ->
        Logger.debug(
          "CleanupVault: vault was restored — skipping",
          Metadata.with_category(:debug, :oban, vault_id: vault_id)
        )

        :ok

      not force and retention_age_secs(vault) < @retention_secs ->
        snooze = @retention_secs - retention_age_secs(vault)

        Logger.debug(
          "CleanupVault: vault not yet at retention — snoozing",
          Metadata.with_category(:debug, :oban, vault_id: vault_id, duration_ms: snooze * 1000)
        )

        {:snooze, snooze}

      true ->
        Logger.info(
          "CleanupVault: starting hard-delete",
          Metadata.with_category(:info, :oban, vault_id: vault_id)
        )

        run_cleanup(vault)
    end
  end

  defp retention_age_secs(vault) do
    DateTime.diff(DateTime.utc_now(), vault.deleted_at, :second)
  end

  # Returns the real owner's id when `vault_id` exists but belongs to someone
  # other than `user_id`, else nil. Only called when the tenant-scoped load
  # came back nil, to tell "already gone" from "not yours".
  #
  # `cross_tenant/1` and not `with_tenant/2`: the whole question is about a row
  # outside the caller's tenant, so there is no tenant that could scope it.
  #
  # On `Repo.maintenance()` because `cross_tenant/1` suppresses only the
  # application guard and sets no Postgres session state. On the app pool once
  # RLS actually applies, this returns nil unconditionally and the caller's
  # `owner_mismatch` branch becomes UNREACHABLE — a forged job targeting another
  # tenant's vault would be indistinguishable from a routine already-deleted
  # one and log at :debug. No data-loss risk either way (the delete at the
  # bottom of this module is properly tenant-scoped), but losing the security
  # signal silently is the whole failure mode of engram-app/Engram#1746.
  #
  # Falls back to `Repo` when no maintenance pool is configured, which is the
  # pre-cutover state the caller's limitation note describes.
  defp foreign_owner(vault_id, user_id) do
    repo = Repo.maintenance()

    Repo.cross_tenant(fn ->
      case repo.get(Vault, vault_id) do
        nil -> nil
        %Vault{user_id: owner} -> if to_string(owner) == to_string(user_id), do: nil, else: owner
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp run_cleanup(vault) do
    # Qdrant is best-effort, so okay before the DB deletes: points are derived
    # data that can be re-indexed.
    delete_qdrant_points(vault)

    # The bulk of the rows first, in id-ordered batches, each its own committed
    # transaction. One transaction over a big vault (every chunk, note with its
    # cascades, attachment) ran past the checkout timeout, rolled back, and was
    # retried forever (2026-10-20 audit, P1-8). Each batch commits its own
    # share of the notes counter and deletes its blobs after commit, so a
    # retry after a crash resumes from whatever is left and double-counts
    # nothing. The final transaction below then handles the small remainder
    # (normally nothing) exactly as before.
    #
    # Every batch, and the final transaction, first locks the vault row and
    # re-checks it is still soft-deleted. A restore landing mid-purge then
    # either waits for the batch in flight or stops the purge at the next one,
    # instead of the remaining batches (and the final vault delete) wiping a
    # vault the user has taken back and may be syncing into.
    with :ok <- mark_purge_started(vault),
         :ok <- delete_batches(vault, Chunk, [:id], fn _rows -> :ok end),
         :ok <-
           delete_batches(vault, Note, [:id, :kind, :deleted_at], &dec_live_notes(vault, &1)),
         :ok <-
           delete_batches(
             vault,
             Attachment,
             [:id, :storage_key],
             fn _rows -> :ok end,
             &blob_keys/1
           ) do
      purge_remainder(vault)
    else
      :restored -> log_restored_mid_purge(vault)
    end
  end

  defp log_restored_mid_purge(vault) do
    Logger.warning(
      "CleanupVault: vault restored mid-purge; stopping",
      Metadata.with_category(:warning, :oban, vault_id: vault.id, user_id: vault.user_id)
    )

    :ok
  end

  # Before the first batch, in its own committed transaction: from here a
  # failed purge leaves the vault partial, and `Vaults.restore_vault/2` refuses
  # a vault with `purge_started_at` set. Kept on a retry (coalesce). The
  # deleted_at re-check under the row lock is the same race guard the batches
  # use: a restore that committed first wins and nothing is stamped.
  defp mark_purge_started(vault) do
    {:ok, n} =
      Repo.with_tenant(vault.user_id, fn ->
        {n, _} =
          from(v in Vault,
            where: v.id == ^vault.id and not is_nil(v.deleted_at),
            update: [
              set: [
                purge_started_at:
                  fragment("coalesce(?, date_trunc('second', now()))", v.purge_started_at)
              ]
            ]
          )
          |> Repo.update_all([])

        n
      end)

    if n == 1, do: :ok, else: :restored
  end

  # Locks the vault row for the rest of the caller's transaction and reports
  # whether it is still soft-deleted (a restore clears `deleted_at`).
  defp locked_for_purge?(vault_id) do
    from(v in Vault,
      where: v.id == ^vault_id and not is_nil(v.deleted_at),
      select: v.id,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
    |> is_binary()
  end

  defp purge_remainder(vault) do
    # Collect storage keys BEFORE deleting the remaining DB rows. Upload
    # sessions are not batch-deleted: the vault row's FK cascade drops them
    # in the final transaction, so they are all still here.
    {storage_keys, multipart_uploads} = collect_storage_keys(vault)

    # DB transaction: delete all rows, making DB authoritative.
    #
    # `with_tenant/2` IS the transaction — it opens one — so this replaces the
    # bare `Repo.transaction/1` rather than nesting inside it. Every write
    # below needs the tenant: a filtered `delete_all` reports `{0, nil}` with
    # no error, and `Repo.delete!(vault)` carries no bypass at all, so a
    # filtered delete would raise `Ecto.StaleEntryError` instead.
    final =
      Repo.with_tenant(vault.user_id, fn ->
        vault_id = vault.id
        if locked_for_purge?(vault_id), do: purge_rows(vault, vault_id), else: :restored
      end)

    case final do
      {:ok, :restored} ->
        log_restored_mid_purge(vault)

      {:ok, {revoked_keys, revoked_grants}} ->
        finish_purge(vault, {storage_keys, multipart_uploads}, revoked_keys, revoked_grants)
    end
  end

  defp purge_rows(vault, vault_id) do
    # Drop the owner's live-note counter by the notes this vault still holds
    # as live (deleted_at IS NULL). Soft-deleted notes were already
    # decremented at soft-delete time, so only the live set counts here.
    live_notes =
      Repo.one(
        from(n in Note,
          where:
            n.vault_id == ^vault_id and is_nil(n.deleted_at) and
              n.kind == "note",
          select: count(n.id)
        )
      ) || 0

    Chunk
    |> where(vault_id: ^vault_id)
    |> Repo.delete_all()

    Note
    |> where(vault_id: ^vault_id)
    |> Repo.delete_all()

    :ok = UsageMeters.dec_notes_count(vault.user_id, live_notes)

    Attachment
    |> where(vault_id: ^vault_id)
    |> Repo.delete_all()

    # Revoke every key that reaches NOTHING once this vault is gone, before
    # its mapping rows go. A pre-#332 key with no `api_key_vaults` rows is
    # unrestricted (`Permissions.from_key/2`), so deleting the mapping
    # would widen a one-vault key to every vault the user owns, and the key
    # can start that itself through `DELETE /api/vaults/:id`. A leveled key
    # whose only reachable vault was this one, with a `none` new-vaults
    # policy, reaches nothing afterwards either. One rule for both kinds
    # (and the one `Connections.revoke_by_vault/2` applies to OAuth
    # grants): the key's scope without this vault reaches nothing. A key
    # with a non-none policy keeps working. Deleting the key cascades its
    # mapping rows. Scoped by `with_tenant` via `api_keys`' own policy.
    live = List.delete(Engram.Vaults.active_vault_ids(vault.user_id), vault_id)

    {revoked, _} =
      from(k in ApiKey, where: k.id in ^keys_left_with_nothing(vault_id, live))
      |> Repo.delete_all()

    # The same judgement for OAuth grants, mirroring keys: soft delete
    # already ran it, but a listed vault purged or deleted since can leave
    # a grant reaching nothing live, and a grant soft delete missed still
    # names this vault. BEFORE the vault row goes: a grant's scalar
    # `vault_id` cascades on delete, so a grant still naming this vault
    # there would vanish uncounted instead of being narrowed or revoked.
    # Kicks the owner's sockets once if a grant changed or a key went.
    revoked_grants =
      Engram.Connections.drop_vault_from_grants(vault.user_id, vault_id, kick_owner: revoked > 0)

    # `api_key_vaults` carries no RLS policy, so the guard never fires for it
    # and the option here is inert either way. Left as-is to keep this diff
    # to the queries that were actually broken.
    from(akv in "api_key_vaults", where: akv.vault_id == type(^vault_id, Ecto.UUID))
    |> Repo.delete_all(skip_tenant_check: true)

    Repo.delete!(vault)
    {revoked, revoked_grants}
  end

  defp finish_purge(vault, {storage_keys, multipart_uploads}, revoked_keys, revoked_grants) do
    # An open socket authenticated with a revoked key or grant must not
    # outlive it: `drop_vault_from_grants/3` kicked the owner once, above.

    # Post-commit: delete storage blobs (best-effort)
    # If this fails, we have orphan blobs but no ghost rows — safe to retry
    Enum.each(multipart_uploads, &abort_multipart/1)
    delete_storage_blobs(storage_keys)

    # Actual user-facing lifecycle event: the vault and all its data are gone.
    Logger.info(
      "CleanupVault: vault permanently deleted",
      Metadata.with_category(:info, :lifecycle,
        vault_id: vault.id,
        user_id: vault.user_id,
        revoked_api_keys: revoked_keys,
        revoked_oauth_grants: revoked_grants
      )
    )

    :ok
  end

  defp batch_size, do: Application.get_env(:engram, :cleanup_vault_batch_size, 1_000)

  # Deletes `schema` rows of `vault`, `batch_size()` at a time in id order,
  # until a batch comes back short. `in_txn` runs inside each batch's
  # transaction with the deleted rows; `after_commit` after it commits.
  defp delete_batches(vault, schema, fields, in_txn, after_commit \\ fn _rows -> :ok end) do
    vault_id = vault.id
    size = batch_size()

    {:ok, result} =
      Repo.with_tenant(vault.user_id, fn ->
        if locked_for_purge?(vault_id),
          do: delete_batch(schema, vault_id, size, fields, in_txn),
          else: :restored
      end)

    case result do
      :restored ->
        :restored

      rows ->
        after_commit.(rows)

        if length(rows) == size,
          do: delete_batches(vault, schema, fields, in_txn, after_commit),
          else: :ok
    end
  end

  defp delete_batch(schema, vault_id, size, fields, in_txn) do
    ids =
      from(r in schema,
        where: r.vault_id == ^vault_id,
        order_by: r.id,
        limit: ^size,
        select: r.id
      )

    # A note's delete cascades into its op log, revisions and links, so a
    # batch costs more than its row count: allow it longer than the
    # default 15s per-statement checkout timeout.
    {_n, rows} =
      from(r in schema, where: r.id in subquery(ids), select: map(r, ^fields))
      |> Repo.delete_all(timeout: :timer.minutes(5))

    :ok = in_txn.(rows)
    rows
  end

  # Soft-deleted notes were decremented at soft-delete time; folder markers
  # are not counted.
  defp dec_live_notes(vault, rows) do
    live = Enum.count(rows, &(&1.kind == "note" and is_nil(&1.deleted_at)))
    UsageMeters.dec_notes_count(vault.user_id, live)
  end

  defp blob_keys(rows) do
    rows |> Enum.map(& &1.storage_key) |> Enum.reject(&is_nil/1) |> delete_storage_blobs()
  end

  # Runs BEFORE the delete transaction, so it needs its own scope. Unscoped it
  # returned `[]`, and the blobs for every attachment in the vault were left
  # in S3 with no row pointing at them — unreachable by any other cleanup path
  # except the weekly orphan sweep.
  #
  # Chunked upload sessions too: a session's blob has no attachment row until
  # complete commits, and the vault FK cascade drops the session row, the only
  # pointer to it. An assembled session holds an object; an unassembled one an
  # open multipart upload, aborted here (the bucket lifecycle rule is only the
  # 7-day backstop).
  defp collect_storage_keys(vault) do
    Repo.with_tenant!(vault.user_id, fn ->
      attachment_keys =
        Attachment
        |> where(vault_id: ^vault.id)
        |> where([a], not is_nil(a.storage_key))
        |> select([a], a.storage_key)
        |> Repo.all()

      sessions =
        Upload
        |> where(vault_id: ^vault.id)
        |> select([u], {u.storage_key, u.s3_upload_id, not is_nil(u.assembled_at)})
        |> Repo.all()

      # A completed session shares its key with the attachment row.
      keys = Enum.uniq(attachment_keys ++ Enum.map(sessions, &elem(&1, 0)))
      multipart = for {key, s3_id, false} <- sessions, do: {key, s3_id}
      {keys, multipart}
    end)
  end

  defp abort_multipart({key, s3_upload_id}) do
    case Engram.Storage.adapter().abort_multipart_upload(key, s3_upload_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "CleanupVault: multipart abort failed",
          Metadata.with_category(:warning, :oban,
            storage_key: key,
            reason: Metadata.safe_reason(reason)
          )
        )
    end
  rescue
    e ->
      Logger.warning(
        "CleanupVault: multipart abort raised",
        Metadata.with_category(:warning, :oban, storage_key: key, reason: Metadata.safe_reason(e))
      )
  end

  defp delete_qdrant_points(vault) do
    case Engram.Vector.Qdrant.delete_by_vault(to_string(vault.user_id), to_string(vault.id)) do
      :ok ->
        Logger.debug(
          "CleanupVault: deleted Qdrant points",
          Metadata.with_category(:debug, :oban, vault_id: vault.id)
        )

      {:error, reason} ->
        Logger.warning(
          "CleanupVault: Qdrant delete failed",
          Metadata.with_category(:warning, :oban,
            vault_id: vault.id,
            reason: Metadata.safe_reason(reason)
          )
        )
    end
  rescue
    e ->
      Logger.warning(
        "CleanupVault: Qdrant delete raised",
        Metadata.with_category(:warning, :oban,
          vault_id: vault.id,
          reason: Metadata.safe_reason(e)
        )
      )
  end

  defp delete_storage_blobs(keys) do
    Enum.each(keys, &delete_storage_blob/1)
  end

  defp delete_storage_blob(key) do
    case Engram.Storage.adapter().delete(key) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "CleanupVault: storage delete failed",
          Metadata.with_category(:warning, :oban,
            storage_key: key,
            reason: Metadata.safe_reason(reason)
          )
        )
    end
  rescue
    e ->
      Logger.warning(
        "CleanupVault: storage delete raised",
        Metadata.with_category(:warning, :oban, storage_key: key, reason: Metadata.safe_reason(e))
      )
  end

  # Keys mapped to `vault_id` whose scope reaches no LIVE vault (`live`, the
  # user's active vaults without this one). Read inside the caller's tenant
  # transaction (`api_keys` RLS).
  defp keys_left_with_nothing(vault_id, live) do
    rows =
      Repo.all(
        from(k in ApiKey,
          join: mine in "api_key_vaults",
          on: mine.api_key_id == k.id and mine.vault_id == type(^vault_id, Ecto.UUID),
          join: akv in "api_key_vaults",
          on: akv.api_key_id == k.id,
          select: {k.id, k.default_access, type(akv.vault_id, Ecto.UUID), akv.level}
        )
      )

    for {key_id, entries} <- Enum.group_by(rows, &elem(&1, 0)),
        {_, default, _, _} = hd(entries),
        scope = Permissions.from_key(default, Enum.map(entries, &{elem(&1, 2), elem(&1, 3)})),
        not Permissions.reaches_anything?(scope, live),
        do: key_id
  end
end
