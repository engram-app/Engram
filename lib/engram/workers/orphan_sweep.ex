defmodule Engram.Workers.OrphanSweep do
  @moduledoc """
  Weekly cross-store orphan reaper.

  Event-driven deletes (`Qdrant.delete_by_user/2`, `Storage.delete_prefix/1`)
  are the primary cleanup path on user/vault/note delete. They are
  best-effort: a network blip or Qdrant timeout leaves orphans behind,
  logged but never retried. This worker is the safety net.

  Sweeps in sequence:

    1. Build authoritative user_id set from `users` (alive + soft-deleted).
    2. Qdrant — scroll all points; group by payload `user_id`; for each
       user_id NOT in the live set, call `Qdrant.delete_by_user/2`.
    3. S3 — list bucket with `delimiter: "/"` to get user_id prefixes;
       for each prefix NOT in the live set, call `Storage.delete_prefix/1`.

  Soft-deleted users are kept in the live set on purpose: we don't want
  this worker racing the inactivity-cleanup ladder. Hard-delete clears
  the row; from then on the orphan-sweep will catch any leftover blobs
  or points on the next weekly tick.

  Telemetry: emits `[:engram, :orphan_sweep, :result]` with counts per
  store. Failures inside a store are logged + counted but do not raise —
  partial cleanup is fine, the next tick catches the rest.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Repo
  alias Engram.Storage
  alias Engram.Vector.Qdrant

  require Logger

  @qdrant_scroll_limit 500

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    live_ids = live_user_ids()

    qdrant_deleted = sweep_qdrant(live_ids)
    s3_deleted = sweep_s3(live_ids)

    :telemetry.execute(
      [:engram, :orphan_sweep, :result],
      %{qdrant_users_swept: qdrant_deleted, s3_prefixes_swept: s3_deleted},
      %{}
    )

    Logger.info(
      "orphan_sweep complete qdrant_users_swept=#{qdrant_deleted} s3_prefixes_swept=#{s3_deleted}"
    )

    :ok
  end

  defp live_user_ids do
    # Includes soft-deleted users (deleted_at IS NOT NULL but row exists) —
    # they are the InactivityCleanup ladder's responsibility, not ours.
    Repo.all(from(u in User, select: u.id)) |> MapSet.new()
  end

  # -- Qdrant --------------------------------------------------------------

  defp sweep_qdrant(live_ids) do
    case discover_qdrant_user_ids() do
      {:ok, qdrant_ids} ->
        orphans = MapSet.difference(qdrant_ids, live_ids)

        Enum.reduce(orphans, 0, fn user_id, acc ->
          case Qdrant.delete_by_user(user_id) do
            :ok ->
              Logger.warning("orphan_sweep deleted Qdrant points user_id=#{user_id}")
              acc + 1

            other ->
              Logger.error(
                "orphan_sweep Qdrant delete failed user_id=#{user_id} reason=#{inspect(other)}"
              )

              acc
          end
        end)

      {:error, reason} ->
        Logger.error("orphan_sweep Qdrant discovery failed reason=#{inspect(reason)}")
        0
    end
  end

  defp discover_qdrant_user_ids, do: scroll_qdrant_ids(nil, MapSet.new())

  defp scroll_qdrant_ids(offset, acc) do
    opts = [
      filter: %{},
      limit: @qdrant_scroll_limit,
      with_payload: ["user_id"],
      with_vector: false
    ]

    opts = if offset, do: Keyword.put(opts, :offset, offset), else: opts

    case Qdrant.scroll(opts) do
      {:ok, %{points: points, next_page_offset: next}} ->
        acc =
          Enum.reduce(points, acc, fn point, set ->
            case get_in(point, ["payload", "user_id"]) do
              uid when is_binary(uid) -> MapSet.put(set, uid)
              _ -> set
            end
          end)

        if next, do: scroll_qdrant_ids(next, acc), else: {:ok, acc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- S3 ------------------------------------------------------------------

  defp sweep_s3(live_ids) do
    case discover_s3_user_prefixes() do
      {:ok, s3_ids} ->
        orphans = MapSet.difference(s3_ids, live_ids)

        Enum.reduce(orphans, 0, fn user_id, acc ->
          case Storage.adapter().delete_prefix("#{user_id}/") do
            {:ok, _count} ->
              Logger.warning("orphan_sweep deleted S3 prefix user_id=#{user_id}")
              acc + 1

            other ->
              Logger.error(
                "orphan_sweep S3 delete failed user_id=#{user_id} reason=#{inspect(other)}"
              )

              acc
          end
        end)

      {:error, reason} ->
        Logger.error("orphan_sweep S3 discovery failed reason=#{inspect(reason)}")
        0
    end
  end

  defp discover_s3_user_prefixes do
    case Storage.adapter().list_user_prefixes() do
      {:ok, ids} -> {:ok, MapSet.new(ids)}
      {:error, _} = err -> err
    end
  end
end
