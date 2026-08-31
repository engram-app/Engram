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
  # The point pass fetches ids only — no payload, no vectors — so a page is
  # ~36 bytes an id and can be far larger than the payload-carrying scroll
  # above. Round trips, not bytes, are what bound a full-collection walk:
  # at 500/page a 10M-point collection is 20k sequential requests and blows
  # the 15-minute timeout; at 4096 it is ~2.4k.
  @point_scroll_limit 4096
  @point_delete_batch 256
  # Ceiling on candidates carried in memory for the confirm pass.
  @max_candidates 50_000
  # Above this share of the scanned collection, the diff is telling us the
  # authority is wrong, not that the points are strays. See `runaway?/2`.
  @max_candidate_ratio 0.10
  # ...but only once enough points are in play for a share to mean anything. A
  # near-empty collection legitimately sits far above the ratio (one stray out
  # of five points is 20%), and refusing to clean small vaults would make the
  # guard the bug.
  @runaway_floor 100
  # Bind parameters per confirm/probe query, against Postgres' 65,535 cap.
  @id_query_batch 5_000

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
  # Diffed a page at a time, never corpus-against-corpus. Holding both id sets
  # measured 106 bytes per uuid — at 1M points that is ~212 MB of MapSet on a
  # 1 GB task, and it grows with the collection. Per page, memory is flat in
  # the collection size and only the (near-empty) candidate set accumulates.
  defp sweep_point_orphans do
    # Scroll BEFORE probing the DB, never after. Indexing inserts chunk rows
    # and THEN upserts points, so probing after the scroll gives the rows the
    # longer window to appear. The other order races outright.
    #
    # This narrows the race, it does not close it: when `commit_index/1` runs
    # inside a `Repo.with_tenant/2` transaction the rows stay invisible to this
    # connection while the points are already public. The grace re-check in
    # `confirm_and_delete/2` is what actually makes that safe.
    case scan_pages(nil, MapSet.new(), 0) do
      {:ok, candidates, scanned} ->
        Logger.info(
          "orphan_sweep scanned Qdrant points",
          Metadata.with_category(:info, :oban,
            total_count: scanned,
            result: %{candidates: MapSet.size(candidates)}
          )
        )

        confirm_and_delete(candidates, scanned)

      {:error, reason} ->
        Logger.error(
          "orphan_sweep point discovery failed",
          Metadata.with_category(:error, :oban, reason: Metadata.safe_reason(reason))
        )

        0
    end
  end

  # Walks the collection one scroll page at a time, probing each page against
  # `chunks` and keeping only the ids no row named.
  defp scan_pages(offset, candidates, scanned) do
    if MapSet.size(candidates) >= @max_candidates do
      # Not silent: a sweep that stops early must say so, or a truncated run
      # reads as a clean one. The next tick resumes from the top and the
      # remainder gets collected then.
      Logger.warning(
        "orphan_sweep candidate cap reached; deferring the rest to the next tick",
        Metadata.with_category(:warning, :oban, total_count: @max_candidates)
      )

      {:ok, candidates, scanned}
    else
      do_scan_page(offset, candidates, scanned)
    end
  end

  defp do_scan_page(offset, candidates, scanned) do
    opts = [filter: %{}, limit: @point_scroll_limit, with_payload: false, with_vector: false]
    opts = if offset, do: Keyword.put(opts, :offset, offset), else: opts

    case Qdrant.scroll(opts) do
      {:ok, %{points: points, next_page_offset: next}} ->
        page = points |> Enum.map(& &1["id"]) |> Enum.filter(&is_binary/1) |> MapSet.new()

        candidates =
          page
          |> MapSet.difference(chunk_point_ids(MapSet.to_list(page)))
          |> MapSet.union(candidates)

        scanned = scanned + MapSet.size(page)

        if next,
          do: scan_pages(next, candidates, scanned),
          else: {:ok, candidates, scanned}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp confirm_and_delete(candidates, scanned) do
    cond do
      MapSet.size(candidates) == 0 ->
        0

      runaway?(candidates, scanned) ->
        # Every delete here is irreversible without a paid re-embed, and the
        # authority we diff against is a database that can be restored, moved,
        # or repointed. A restore from a backup older than the last embed wave
        # makes EVERY recent point look orphaned; without this guard the next
        # tick quietly deletes them all. A real stray population is a handful
        # of points, never a large fraction of the collection, so a ratio this
        # high means the premise is broken rather than the data.
        Logger.error(
          "orphan_sweep aborting: candidate ratio implies a bad authority, not strays",
          Metadata.with_category(:error, :oban,
            total_count: MapSet.size(candidates),
            result: %{scanned: scanned, max_ratio: @max_candidate_ratio}
          )
        )

        0

      true ->
        # Second look after a grace window. The window exists for ONE reason:
        # `Indexing.commit_index/1` inserts chunk rows and upserts points in the
        # same breath, and a tenant-scoped caller wraps that in
        # `Repo.with_tenant/2`, which opens a transaction. Inside it the rows
        # are invisible to this worker's connection while the points are
        # already globally visible — so a page scrolled mid-write yields
        # candidates whose rows land moments later.
        #
        # It is NOT protection against a re-index reusing point ids: re-index
        # mints a fresh uuid per chunk, so a candidate id can never come back
        # that way. Do not delete this as ceremony.
        grace()

        confirmed = MapSet.difference(candidates, chunk_point_ids(MapSet.to_list(candidates)))
        delete_points(MapSet.to_list(confirmed))
    end
  end

  defp runaway?(candidates, scanned) do
    n = MapSet.size(candidates)
    n >= @runaway_floor and scanned > 0 and n / scanned > @max_candidate_ratio
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
  # still live. Indexed lookup on `chunks.qdrant_point_id`, bounded by the
  # caller's page/candidate list — never a whole-table read.
  #
  # Chunked: one bind parameter per id against Postgres' 65,535 statement cap.
  # A page is 4,096 and the candidate list can reach the cap plus a page, so
  # neither caller is close today — but both are constants someone will raise,
  # and the failure mode is the confirm query raising mid-sweep.
  defp chunk_point_ids(ids) do
    ids
    |> cast_uuids()
    |> Enum.chunk_every(@id_query_batch)
    |> Enum.reduce(MapSet.new(), fn batch, acc ->
      Chunk
      |> where([c], c.qdrant_point_id in ^batch)
      |> select([c], c.qdrant_point_id)
      |> Repo.all(skip_tenant_check: true)
      |> Enum.reject(&is_nil/1)
      |> Enum.into(acc)
    end)
  end

  # Qdrant ids are whatever the collection holds; ours are uuids, but one
  # malformed value would raise `Ecto.Query.CastError` out of a `max_attempts: 1`
  # worker and kill the pass mid-walk. Same guard as
  # `Notes.display_fields_by_qdrant_points/2` on the identical query.
  defp cast_uuids(ids) do
    Enum.flat_map(ids, fn id ->
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> [uuid]
        :error -> []
      end
    end)
  end

  defp grace do
    case Application.get_env(:engram, :orphan_sweep_point_grace_fun) do
      fun when is_function(fun, 0) -> fun.()
      _ -> Process.sleep(grace_seconds() * 1000)
    end
  end

  defp grace_seconds,
    do: Application.get_env(:engram, :orphan_sweep_point_grace_seconds, 60)

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
