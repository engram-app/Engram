defmodule Engram.Workers.AttachmentBlobGC do
  @moduledoc """
  Hourly reaper for the blobs of soft-deleted attachments (#2159).

  A soft delete never touches storage. It used to delete the blob in the same
  request, which is irreversible, while the row change it followed could still
  roll back (a folder cascade wrapping it in a longer transaction). The result
  was live rows with no bytes. Now the database reference goes first and the
  bytes go later, here, the way GitLab LFS, Nextcloud and Immich do it.

  A tombstone is reaped once it is `@grace_hours` old, still holds a
  `storage_key`, and no live row references that key. Per vault, per batch,
  one transaction locks the vault row (the lock every key-assigning write
  takes first), locks the tombstones `FOR UPDATE SKIP LOCKED`, re-checks the
  live-row condition under those locks and clears their `storage_key`. Only
  after that commits are exactly those blobs deleted, so the destructive
  call never races a live row gaining the key. A key whose delete fails is
  written back onto its tombstone and retried on the next run. Pages are
  keyset by id, so a stuck key never blocks the rows after it.

  Recovery window: `@grace_hours`, plus the bucket's noncurrent-version
  retention once the blob is gone.

  Refuses under `Repo.tenancy_unsafe?/0`. A blind role reads zero rows, so
  today that would reap nothing rather than something wrong; the guard keeps
  it that way if the tombstone read and the live-row check ever stop being
  blind together (one on a pool that sees, one that does not), and makes the
  misconfiguration loud instead of a silent no-op.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.Logger.Metadata
  alias Engram.Repo
  alias Engram.Storage
  alias Engram.Vaults.Vault

  require Logger

  @grace_hours 24
  @batch 1_000

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
    cutoff = DateTime.add(DateTime.utc_now(), -@grace_hours * 3600, :second)

    cutoff
    |> candidate_vaults()
    |> Enum.reduce(0, fn vault_id, reaped -> reaped + sweep_vault(vault_id, cutoff, nil, 0) end)
  end

  # Unlocked, and only to find work: every decision is re-made under the
  # locks in `claim/3`.
  defp candidate_vaults(cutoff) do
    query =
      from(a in eligible(cutoff),
        distinct: true,
        order_by: a.vault_id,
        select: a.vault_id
      )

    Repo.cross_tenant(fn -> Repo.maintenance().all(query) end)
  end

  defp sweep_vault(vault_id, cutoff, after_id, reaped) do
    case claim(vault_id, cutoff, after_id) do
      {[], _last} ->
        reaped

      {claimed, last} ->
        n = reaped + delete_claimed(claimed)
        if last, do: sweep_vault(vault_id, cutoff, last, n), else: n
    end
  end

  # ONE transaction per batch, so each key has one owner who commits before
  # the destructive call (#2159 follow-up):
  #   1. the vault row, FOR NO KEY UPDATE: the same lock every write that
  #      gives a row a key takes first (LOCK ORDER, `Engram.Vaults`), so no
  #      live row can gain a key in this vault until this commits;
  #   2. the tombstones, FOR UPDATE SKIP LOCKED, re-checked under those locks
  #      that no live row holds the key;
  #   3. their storage_key cleared; the keys read in step 2 are now this
  #      batch's.
  # Only after commit are those blobs deleted (`delete_claimed/1`). Returns
  # `{claimed, last_id}`, `last_id` nil when this was the vault's last page.
  defp claim(vault_id, cutoff, after_id) do
    repo = Repo.maintenance()

    {:ok, result} =
      Repo.cross_tenant(fn ->
        repo.transaction(fn ->
          _ =
            repo.all(
              from(v in Vault, where: v.id == ^vault_id, lock: "FOR NO KEY UPDATE", select: v.id)
            )

          query =
            from(a in eligible(cutoff),
              where: a.vault_id == ^vault_id,
              order_by: a.id,
              limit: @batch,
              lock: "FOR UPDATE SKIP LOCKED",
              select: {a.id, a.storage_key}
            )

          query = if after_id, do: where(query, [a], a.id > ^after_id), else: query
          # Keys read under the lock: RETURNING would give the new (nil) value.
          rows = repo.all(query)
          ids = Enum.map(rows, &elem(&1, 0))

          {_n, _} =
            repo.update_all(from(a in Attachment, where: a.id in ^ids), set: [storage_key: nil])

          {rows, if(length(rows) == @batch, do: List.last(ids))}
        end)
      end)

    result
  end

  # A tombstone past the grace window that still holds a key no live row has.
  defp eligible(cutoff) do
    from(a in Attachment,
      as: :tomb,
      where:
        not is_nil(a.deleted_at) and a.deleted_at < ^cutoff and not is_nil(a.storage_key) and
          not exists(
            from(l in Attachment,
              where: l.storage_key == parent_as(:tomb).storage_key and is_nil(l.deleted_at),
              select: 1
            )
          )
    )
  end

  # Deletes the blobs whose keys this batch committed. A key whose delete
  # fails goes back on its tombstone, so the next run retries it with the
  # same claim protocol (no pending table: the tombstone is the record).
  # Returns how many blobs are gone.
  defp delete_claimed(claimed) do
    gone = deleted_keys(claimed)
    failed = Enum.reject(claimed, fn {_id, key} -> MapSet.member?(gone, key) end)
    Enum.each(failed, &restore_key/1)
    length(claimed) - length(failed)
  end

  defp restore_key({id, key}) do
    Repo.cross_tenant(fn ->
      Repo.maintenance().update_all(
        from(a in Attachment,
          where: a.id == ^id and is_nil(a.storage_key) and not is_nil(a.deleted_at)
        ),
        set: [storage_key: key]
      )
    end)
  end

  # The keys whose blob is gone. One batched call; if any key in it failed,
  # fall back to one call per key so the batch's good keys still count.
  defp deleted_keys(rows) do
    keys = rows |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    case Storage.adapter().delete_many(keys) do
      {:ok, n} when n == length(keys) -> MapSet.new(keys)
      _ -> keys |> Enum.filter(&delete_one/1) |> MapSet.new()
    end
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
