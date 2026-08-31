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
    4. Qdrant points — scroll every point id; delete the ones no
       `chunks.qdrant_point_id` names. Catches a LIVE user's stranded points,
       which step 2 is blind to (it only reaps whole departed user_ids).

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
  alias Engram.Logger.Metadata
  alias Engram.Notes.Chunk
  alias Engram.Repo
  alias Engram.Storage
  alias Engram.Vector.Qdrant

  require Logger

  @qdrant_scroll_limit 500
  @point_delete_batch 256

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    live_ids = live_user_ids()

    qdrant_deleted = sweep_qdrant(live_ids)
    s3_deleted = sweep_s3(live_ids)
    points_deleted = sweep_point_orphans()

    :telemetry.execute(
      [:engram, :orphan_sweep, :result],
      %{
        qdrant_users_swept: qdrant_deleted,
        s3_prefixes_swept: s3_deleted,
        qdrant_points_swept: points_deleted
      },
      %{}
    )

    Logger.info(
      "orphan_sweep complete",
      Metadata.with_category(:info, :oban,
        total_count: qdrant_deleted + s3_deleted + points_deleted,
        result: %{
          qdrant_users_swept: qdrant_deleted,
          s3_prefixes_swept: s3_deleted,
          qdrant_points_swept: points_deleted
        }
      )
    )

    :ok
  end

  # -- Point-level orphans -------------------------------------------------

  # The user-level sweep above only fires when a whole user_id has left the
  # DB. It cannot see a LIVE user's stranded points, which is the common case:
  # a rename retags `notes.path_hmac` while the points keep the old hmac, and a
  # delete landing inside the debounce window filters on the new one, matches
  # nothing, then drops the chunk rows that named the points.
  #
  # Authority is `chunks.qdrant_point_id`: a point no row names is unreachable
  # by every other cleanup path and can never be returned to a user.
  #
  # ponytail: whole-collection scroll + one id set in memory. Fine to ~1M
  # points; shard by user_id if the collection outgrows that.
  defp sweep_point_orphans do
    # Scroll BEFORE reading the DB, never after. Indexing inserts chunk rows
    # and THEN upserts points, so anything this scroll sees already has its row
    # committed by the time the read below runs. The other order would race.
    case scroll_qdrant_point_ids(nil, MapSet.new()) do
      {:ok, point_ids} ->
        candidates = MapSet.difference(point_ids, chunk_point_ids())
        confirm_and_delete(candidates)

      {:error, reason} ->
        Logger.error(
          "orphan_sweep point discovery failed",
          Metadata.with_category(:error, :oban, reason: Metadata.safe_reason(reason))
        )

        0
    end
  end

  defp confirm_and_delete(candidates) do
    if MapSet.size(candidates) == 0 do
      0
    else
      # Second look after a grace window. A sweep can straddle an in-flight
      # re-index (chunk rows are deleted and re-inserted, not updated in
      # place), and deleting a live point would silently drop a note out of
      # search until something re-embedded it. Re-checking only the candidates
      # is a single small query.
      grace()

      confirmed = MapSet.difference(candidates, chunk_point_ids(MapSet.to_list(candidates)))
      delete_points(MapSet.to_list(confirmed))
    end
  end

  defp delete_points([]), do: 0

  defp delete_points(ids) do
    ids
    |> Enum.chunk_every(@point_delete_batch)
    |> Enum.reduce(0, fn batch, acc ->
      case Qdrant.delete_points(batch) do
        :ok ->
          Logger.info(
            "orphan_sweep deleted stranded Qdrant points",
            Metadata.with_category(:info, :oban, total_count: length(batch))
          )

          acc + length(batch)

        other ->
          Logger.error(
            "orphan_sweep point delete failed",
            Metadata.with_category(:error, :oban, reason: Metadata.safe_reason(other))
          )

          acc
      end
    end)
  end

  # skip_tenant_check: cross-tenant by design — this is a whole-collection
  # reconciliation, and RLS would hide exactly the rows that prove a point is
  # still live.
  defp chunk_point_ids do
    Chunk
    |> select([c], c.qdrant_point_id)
    |> Repo.all(skip_tenant_check: true)
    |> to_id_set()
  end

  defp chunk_point_ids(ids) do
    Chunk
    |> where([c], c.qdrant_point_id in ^ids)
    |> select([c], c.qdrant_point_id)
    |> Repo.all(skip_tenant_check: true)
    |> to_id_set()
  end

  defp to_id_set(ids) do
    ids |> Enum.reject(&is_nil/1) |> Enum.map(&to_string/1) |> MapSet.new()
  end

  defp grace do
    case Application.get_env(:engram, :orphan_sweep_point_grace_fun) do
      fun when is_function(fun, 0) -> fun.()
      _ -> Process.sleep(grace_seconds() * 1000)
    end
  end

  defp grace_seconds,
    do: Application.get_env(:engram, :orphan_sweep_point_grace_seconds, 60)

  defp scroll_qdrant_point_ids(offset, acc) do
    opts = [filter: %{}, limit: @qdrant_scroll_limit, with_payload: false, with_vector: false]
    opts = if offset, do: Keyword.put(opts, :offset, offset), else: opts

    case Qdrant.scroll(opts) do
      {:ok, %{points: points, next_page_offset: next}} ->
        acc =
          Enum.reduce(points, acc, fn point, set ->
            case point["id"] do
              id when is_binary(id) -> MapSet.put(set, id)
              _ -> set
            end
          end)

        if next, do: scroll_qdrant_point_ids(next, acc), else: {:ok, acc}

      {:error, reason} ->
        {:error, reason}
    end
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
              Logger.debug(
                "orphan_sweep deleted Qdrant points",
                Metadata.with_category(:debug, :oban, user_id: user_id)
              )

              acc + 1

            other ->
              Logger.error(
                "orphan_sweep Qdrant delete failed",
                Metadata.with_category(:error, :oban,
                  user_id: user_id,
                  reason: Metadata.safe_reason(other)
                )
              )

              acc
          end
        end)

      {:error, reason} ->
        Logger.error(
          "orphan_sweep Qdrant discovery failed",
          Metadata.with_category(:error, :oban, reason: Metadata.safe_reason(reason))
        )

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
              Logger.debug(
                "orphan_sweep deleted S3 prefix",
                Metadata.with_category(:debug, :oban, user_id: user_id)
              )

              acc + 1

            other ->
              Logger.error(
                "orphan_sweep S3 delete failed",
                Metadata.with_category(:error, :oban,
                  user_id: user_id,
                  reason: Metadata.safe_reason(other)
                )
              )

              acc
          end
        end)

      {:error, reason} ->
        Logger.error(
          "orphan_sweep S3 discovery failed",
          Metadata.with_category(:error, :oban, reason: Metadata.safe_reason(reason))
        )

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
