defmodule Engram.Workers.AttachmentBlobGC do
  @moduledoc """
  Hourly reaper for the blobs of soft-deleted attachments (#2159).

  A soft delete never touches storage. It used to delete the blob in the same
  request, which is irreversible, while the row change it followed could still
  roll back (a folder cascade wrapping it in a longer transaction). The result
  was live rows with no bytes. Now the database reference goes first and the
  bytes go later, here, the way GitLab LFS, Nextcloud and Immich do it.

  A tombstone is reaped once it is older than its owner's trash retention
  (`Engram.Billing.trash_retention_days/1`, #609: until then a restore can
  bring it back), still holds a `storage_key`, and no live row references
  that key. Per vault and batch,
  in three phases so no transaction is held across S3 and no crash orphans
  a blob:

    1. claim: one short transaction locks the vault row, then the tombstones
       `FOR UPDATE SKIP LOCKED`, re-checks the live-row condition under those
       locks, and stamps `blob_gc_claimed_at`. The key stays on the row.
    2. delete the claimed blobs, outside any transaction.
    3. finalize: clear `storage_key` and the stamp for the keys S3 confirmed,
       guarded by key and stamp; clear only the stamp for failed keys so the
       next run retries.

  A run that dies between 1 and 3 leaves stamp and key in place; once the
  stamp is older than `@stale_claim_minutes` the row is eligible again and
  is re-claimed (re-checked) and re-deleted, which is idempotent. Pages are
  keyset by id, so a stuck key never blocks the rows after it.

  Recovery window: the owner's trash retention, plus the bucket's
  noncurrent-version retention once the blob is gone.

  Refuses under `Repo.tenancy_unsafe?/0`. A blind role reads zero rows, so
  today that would reap nothing rather than something wrong; the guard keeps
  it that way if the tombstone read and the live-row check ever stop being
  blind together (one on a pool that sees, one that does not), and makes the
  misconfiguration loud instead of a silent no-op.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Attachments.Attachment
  alias Engram.Billing
  alias Engram.Logger.Metadata
  alias Engram.Repo
  alias Engram.Storage
  alias Engram.Vaults.Vault

  require Logger

  # Candidate discovery only: no retention is shorter than a day
  # (`Billing.trash_retention_days/1` floors at 1), so nothing younger can be
  # due. The real cutoff is per vault owner.
  @min_retention_days 1
  # Well above the 15 min job timeout: a claim this old belongs to a run
  # that died, so it may be taken again.
  @stale_claim_minutes 60
  @batch 1_000

  @doc """
  Minutes after which a claim is treated as belonging to a dead run. Also
  the age below which `Engram.Attachments.revive_tombstones/3` refuses a
  claimed row (#2195): a younger claim may be mid-delete.
  """
  @spec stale_claim_minutes() :: 60
  def stale_claim_minutes, do: @stale_claim_minutes

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(_job) do
    if Repo.tenancy_unsafe?() do
      Logger.error(
        "attachment_blob_gc refusing to run: RLS is enforced and no maintenance pool is " <>
          "configured, so every blob would look unreferenced",
        Metadata.with_category(:error, :oban, [])
      )

      {:error, :tenancy_unsafe}
    else
      reaped = sweep()

      Logger.info(
        "attachment_blob_gc complete",
        Metadata.with_category(:info, :oban, total_count: reaped)
      )

      :ok
    end
  end

  @doc "Reaps every eligible tombstone blob. Returns how many were reaped."
  @spec sweep() :: non_neg_integer()
  def sweep do
    now = DateTime.utc_now()

    now
    |> DateTime.add(-@min_retention_days, :day)
    |> candidate_vaults()
    |> Enum.reduce(0, fn {vault_id, user_id}, reaped ->
      case retention_cutoff(user_id, now) do
        nil -> reaped
        cutoff -> reaped + sweep_vault(vault_id, cutoff, nil, 0)
      end
    end)
  end

  # The owner's retention, read through the same resolver a restore uses so
  # the two windows cannot disagree. Read on the maintenance pool: the GC
  # has no tenant. A vanished owner reaps nothing here; account deletion
  # owns that cleanup.
  defp retention_cutoff(user_id, now) do
    case Repo.cross_tenant(fn -> Repo.maintenance().get(User, user_id) end) do
      %User{} = user -> DateTime.add(now, -Billing.trash_retention_days(user), :day)
      nil -> nil
    end
  end

  # Unlocked, and only to find work: every decision is re-made under the
  # locks in `claim/3`.
  defp candidate_vaults(cutoff) do
    stale = DateTime.add(DateTime.utc_now(), -@stale_claim_minutes * 60, :second)

    query =
      from(a in eligible(cutoff, stale),
        distinct: true,
        order_by: a.vault_id,
        select: {a.vault_id, a.user_id}
      )

    Repo.cross_tenant(fn -> Repo.maintenance().all(query) end)
  end

  defp sweep_vault(vault_id, cutoff, after_id, reaped) do
    case claim(vault_id, cutoff, after_id) do
      {[], _claimed_at, _last} ->
        reaped

      {claimed, claimed_at, last} ->
        case finish(claimed, claimed_at) do
          {:ok, n} when is_binary(last) -> sweep_vault(vault_id, cutoff, last, reaped + n)
          {:ok, n} -> reaped + n
          # The storage client raised: stop this vault (pages already reaped
          # count), leave this batch's claims for the stale threshold, and go
          # on to the next vault.
          :storage_raised -> reaped
        end
    end
  end

  # Phase 1, the claim: ONE short transaction with no I/O.
  #   1. the vault row, FOR NO KEY UPDATE (see the invariant below);
  #   2. the eligible tombstones, FOR UPDATE SKIP LOCKED, with the "no live
  #      row has this key" check re-made as a fresh statement under the lock;
  #   3. `blob_gc_claimed_at` stamped on them. `storage_key` is KEPT.
  # Returns `{[{id, key}], claimed_at, last_id}`; `last_id` is nil on the
  # vault's last page.
  #
  # Invariant the vault lock relies on: a key is only ever minted fresh (every
  # upload) or kept by its own live row (rename, restore, DEK rotation); no
  # path copies a tombstone's key onto a live row. Writers commit key changes
  # under the vault row lock (via `next_seq!`/`lock_seq!`). A future path that
  # copies a tombstone's key must read it AFTER taking that lock, or this
  # re-check cannot see it. Likewise a future undelete must take the vault
  # lock and must not revive a row that carries a fresh `blob_gc_claimed_at`
  # (its blob may be mid-delete); `Attachments.revive_tombstones/3` is that
  # path and does both (#2195). Finalize also refuses to touch a live row.
  defp claim(vault_id, cutoff, after_id) do
    repo = Repo.maintenance()
    claimed_at = DateTime.utc_now()
    stale = DateTime.add(claimed_at, -@stale_claim_minutes * 60, :second)

    {:ok, result} =
      Repo.cross_tenant(fn ->
        repo.transaction(fn ->
          _ =
            repo.all(
              from(v in Vault, where: v.id == ^vault_id, lock: "FOR NO KEY UPDATE", select: v.id)
            )

          query =
            from(a in eligible(cutoff, stale),
              where: a.vault_id == ^vault_id,
              order_by: a.id,
              limit: @batch,
              lock: "FOR UPDATE SKIP LOCKED",
              select: {a.id, a.storage_key}
            )

          query = if after_id, do: where(query, [a], a.id > ^after_id), else: query
          rows = repo.all(query)
          ids = Enum.map(rows, &elem(&1, 0))

          {_n, _} =
            repo.update_all(from(a in Attachment, where: a.id in ^ids),
              set: [blob_gc_claimed_at: claimed_at]
            )

          {rows, claimed_at, if(length(rows) == @batch, do: List.last(ids))}
        end)
      end)

    result
  end

  # A tombstone past the retention cutoff that still holds a key no live row
  # has, unclaimed or holding a claim older than the stale threshold (a run
  # that died between claim and finalize).
  defp eligible(cutoff, stale) do
    from(a in Attachment,
      as: :tomb,
      where:
        not is_nil(a.deleted_at) and a.deleted_at < ^cutoff and not is_nil(a.storage_key) and
          (is_nil(a.blob_gc_claimed_at) or a.blob_gc_claimed_at < ^stale) and
          not exists(
            from(l in Attachment,
              where: l.storage_key == parent_as(:tomb).storage_key and is_nil(l.deleted_at),
              select: 1
            )
          )
    )
  end

  # Phases 2 and 3: delete the claimed blobs outside any transaction, then
  # finalize. Deleted keys: `storage_key` and the stamp cleared, guarded by
  # the key AND this run's stamp, so a row that changed or was re-claimed
  # since is left alone. Failed keys: the stamp cleared, so the next run
  # retries. A crash anywhere here leaves the stamp and the key, and the
  # stale threshold brings the row back. Returns how many were reaped.
  defp finish(claimed, claimed_at) do
    case deleted_keys(claimed) do
      {:ok, gone} ->
        {done, failed} = Enum.split_with(claimed, fn {_id, key} -> MapSet.member?(gone, key) end)

        reaped =
          finalize(done, claimed_at,
            set: [storage_key: nil, blob_gc_claimed_at: nil],
            label: "deleted"
          )

        _ = finalize(failed, claimed_at, set: [blob_gc_claimed_at: nil], label: "released")
        {:ok, reaped}

      :storage_raised ->
        :storage_raised
    end
  end

  defp finalize([], _claimed_at, _opts), do: 0

  defp finalize(rows, claimed_at, set: set, label: label) do
    ids = Enum.map(rows, &elem(&1, 0))
    keys = Enum.map(rows, &elem(&1, 1))

    {_n, matched} =
      Repo.cross_tenant(fn ->
        Repo.maintenance().update_all(
          from(a in Attachment,
            where:
              a.id in ^ids and a.storage_key in ^keys and a.blob_gc_claimed_at == ^claimed_at and
                not is_nil(a.deleted_at),
            select: a.id
          ),
          set: set
        )
      end)

    if length(matched) < length(rows), do: log_unmatched(label, ids -- matched, length(rows))

    length(matched)
  end

  # A deleted key whose row no longer matches (went live, changed key, or was
  # re-claimed) may be a live row whose blob is now gone: error, with the ids,
  # so it can be restored from the bucket's noncurrent versions.
  defp log_unmatched("deleted", unmatched, key_count) do
    Logger.error(
      "attachment_blob_gc: blob deleted but its row was not finalized; check these rows",
      Metadata.with_category(:error, :oban,
        key_count: key_count,
        # Joined: the console formatter drops list values.
        attachment_ids: unmatched |> Enum.take(50) |> Enum.join(",")
      )
    )
  end

  defp log_unmatched(label, unmatched, key_count) do
    Logger.warning(
      "attachment_blob_gc: finalize matched fewer rows than it #{label}",
      Metadata.with_category(:warning, :oban,
        key_count: key_count,
        total_count: key_count - length(unmatched)
      )
    )
  end

  # The keys whose blob is gone. One batched call; if any key in it failed,
  # fall back to one call per key so the batch's good keys still count.
  #
  # Only this storage call is rescued: a client that raises is the S3 side
  # failing, and it must not stop the other vaults. Database errors in the
  # claim and finalize are NOT rescued, so the job fails and Oban records it.
  defp deleted_keys(rows) do
    keys = rows |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    gone =
      case Storage.adapter().delete_many(keys) do
        {:ok, n} when n == length(keys) -> MapSet.new(keys)
        _ -> keys |> Enum.filter(&delete_one/1) |> MapSet.new()
      end

    {:ok, gone}
  rescue
    e ->
      Logger.warning(
        "attachment_blob_gc: blob delete raised, its claims retry after the stale threshold",
        Metadata.with_category(:warning, :oban,
          key_count: length(rows),
          reason: Metadata.safe_reason(e)
        )
      )

      :storage_raised
  end

  defp delete_one(key) do
    case Storage.adapter().delete(key) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning(
          "attachment_blob_gc: blob delete failed, retrying next run",
          Metadata.with_category(:warning, :oban,
            storage_key: key,
            reason: Metadata.safe_reason(reason)
          )
        )

        false
    end
  end
end
