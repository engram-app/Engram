defmodule Engram.Workers.AttachmentBlobGC do
  @moduledoc """
  Hourly reaper for the blobs of soft-deleted attachments (#2159).

  A soft delete never touches storage. It used to delete the blob in the same
  request, which is irreversible, while the row change it followed could still
  roll back (a folder cascade wrapping it in a longer transaction). The result
  was live rows with no bytes. Now the database reference goes first and the
  bytes go later, here, the way GitLab LFS, Nextcloud and Immich do it.

  A tombstone is reaped once it is `@grace_hours` old, still holds a
  `storage_key`, and no live row references that key. Its blob is deleted,
  then its `storage_key` is set to NULL, so a later run skips it. A key whose
  delete fails keeps its `storage_key` and is retried on the next run. Pages
  are keyset by id, so a stuck key never blocks the rows after it.

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
    sweep(cutoff, nil, 0)
  end

  defp sweep(cutoff, after_id, reaped) do
    case page(cutoff, after_id) do
      [] ->
        reaped

      rows ->
        n = reap(rows)
        {last_id, _key} = List.last(rows)
        if length(rows) < @batch, do: reaped + n, else: sweep(cutoff, last_id, reaped + n)
    end
  end

  defp page(cutoff, after_id) do
    query =
      from(a in Attachment,
        as: :tomb,
        where:
          not is_nil(a.deleted_at) and a.deleted_at < ^cutoff and not is_nil(a.storage_key) and
            not exists(
              from(l in Attachment,
                where: l.storage_key == parent_as(:tomb).storage_key and is_nil(l.deleted_at),
                select: 1
              )
            ),
        order_by: a.id,
        limit: @batch,
        select: {a.id, a.storage_key}
      )

    query = if after_id, do: where(query, [a], a.id > ^after_id), else: query
    Repo.cross_tenant(fn -> Repo.maintenance().all(query) end)
  end

  defp reap(rows) do
    deleted_ids =
      rows
      |> deleted_keys()
      |> then(fn keys -> for {id, key} <- rows, MapSet.member?(keys, key), do: id end)

    # Counted from RETURNING: `Repo.maintenance/0` picks the repo at runtime,
    # so update_all's count is untyped and would widen the spec to number().
    {_n, reaped} =
      Repo.cross_tenant(fn ->
        Repo.maintenance().update_all(
          from(a in Attachment,
            where: a.id in ^deleted_ids and not is_nil(a.deleted_at),
            select: a.id
          ),
          set: [storage_key: nil]
        )
      end)

    length(reaped)
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
