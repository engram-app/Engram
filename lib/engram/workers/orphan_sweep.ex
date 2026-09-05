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
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Storage
  alias Engram.Vaults.Vault
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
  # Chunk rows probed against Qdrant per round trip (#1576). Smaller than the
  # id-only scroll above because `has_id` carries every id in the REQUEST body,
  # not just the response. Validated against prod at this size.
  @chunk_probe_batch 2048
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
  def perform(%Oban.Job{args: args}) do
    live_ids = live_user_ids()

    qdrant_deleted = sweep_qdrant(live_ids)
    s3_deleted = sweep_s3(live_ids)
    points_deleted = sweep_point_orphans()
    notes_flagged = sweep_missing_points(force: Map.get(args, "force", false))

    :telemetry.execute(
      [:engram, :orphan_sweep, :result],
      %{
        qdrant_users_swept: qdrant_deleted,
        s3_prefixes_swept: s3_deleted,
        qdrant_points_swept: points_deleted,
        notes_flagged_for_reindex: notes_flagged
      },
      %{}
    )

    Logger.info(
      "orphan_sweep complete",
      Metadata.with_category(:info, :oban,
        total_count: qdrant_deleted + s3_deleted + points_deleted + notes_flagged,
        result: %{
          qdrant_users_swept: qdrant_deleted,
          s3_prefixes_swept: s3_deleted,
          qdrant_points_swept: points_deleted,
          notes_flagged_for_reindex: notes_flagged
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

  # -- Missing points (the Postgres->Qdrant direction) ----------------------

  # #1576. `sweep_point_orphans/0` above answers "does a chunk row still name
  # this point?". This answers the opposite, and nothing else in the system
  # does: "does Qdrant still hold the point this chunk row names?".
  #
  # It has to be asked because `ReconcileEmbeddings` decides a note is indexed
  # by comparing `embed_hash` to `content_hash` — two Postgres columns. A
  # Postgres restore rolls the data and that bookkeeping back together, so they
  # stay mutually consistent while Qdrant does not: every note re-indexed after
  # the restore point has vectors under ids that were minted later and deleted
  # when the rows were, and it still reads as freshly indexed. Silently
  # unsearchable, forever, with no self-heal.
  #
  # Nulling the index hashes is the whole repair. `ReconcileEmbeddings` rebuilds
  # from there on its next tick, with its own entitlement and poison-cooldown
  # checks intact — this worker deliberately owns no rebuild path of its own.
  defp sweep_missing_points(opts) do
    case scan_chunk_pages(nil, [], 0) do
      {:ok, [], scanned} ->
        Logger.info(
          "orphan_sweep probed chunk points",
          Metadata.with_category(:info, :oban, total_count: scanned, result: %{missing: 0})
        )

        0

      {:ok, candidates, scanned} ->
        Logger.info(
          "orphan_sweep probed chunk points",
          Metadata.with_category(:info, :oban,
            total_count: scanned,
            result: %{missing: length(candidates)}
          )
        )

        confirm_and_flag(candidates, scanned, opts)

      {:error, reason} ->
        # A Qdrant failure must never read as "every point is gone". Bailing
        # keeps the ratio guard below from being the only thing between a
        # transient outage and a corpus-wide re-embed.
        Logger.error(
          "orphan_sweep chunk-point probe failed",
          Metadata.with_category(:error, :oban, reason: Metadata.safe_reason(reason))
        )

        0
    end
  end

  # Keyset paging on `chunks.id`, probing Qdrant once per page. Memory is flat
  # in the table size: one page of ids plus the (near-empty) candidate list.
  #
  # Order matters and is the mirror of the forward pass. Read Postgres FIRST,
  # probe Qdrant second: `Indexing.commit_index/1` inserts chunk rows and THEN
  # upserts points, so probing after the read gives the points the longer
  # window to appear. The other order races outright.
  defp scan_chunk_pages(after_id, candidates, scanned) do
    if length(candidates) >= max_missing_candidates() do
      # Same bound the forward pass keeps, for the same reason: the runaway
      # check can only run once the walk is done, so without a cap an empty or
      # repointed collection makes the worker hold a tuple per chunk row for
      # the entire table before it decides to abort. Not silent — a truncated
      # run that reads as a clean one is worse than a loud partial one.
      Logger.warning(
        "orphan_sweep missing-point candidate cap reached; deferring the rest to the next tick",
        Metadata.with_category(:warning, :oban, total_count: length(candidates))
      )

      {:ok, candidates, scanned}
    else
      do_scan_chunk_page(after_id, candidates, scanned)
    end
  end

  defp do_scan_chunk_page(after_id, candidates, scanned) do
    case chunk_page(after_id) do
      [] ->
        {:ok, candidates, scanned}

      rows ->
        case qdrant_points_present(Enum.map(rows, fn {_id, _note_id, pid} -> pid end)) do
          {:ok, present} ->
            missing =
              for {_id, note_id, pid} <- rows,
                  not MapSet.member?(present, pid),
                  do: {note_id, pid}

            {last_id, _note_id, _pid} = List.last(rows)

            # Prepended, not appended: `candidates ++ missing` re-copies the
            # accumulator once per page, which is O(n^2) over a walk that only
            # gets long in the runaway case this is trying to survive. Order
            # carries no meaning here.
            scan_chunk_pages(last_id, missing ++ candidates, scanned + length(rows))

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp confirm_and_flag(candidates, scanned, opts) do
    forced = Keyword.get(opts, :force, false)

    if not forced and runaway?(MapSet.new(candidates), scanned) do
      # Same reasoning as the forward pass, pointed the other way and with a
      # bigger bill attached: if Qdrant is unreachable, empty, or repointed at
      # the wrong collection, EVERY chunk looks stranded. Acting on that nulls
      # the whole corpus and re-bills Voyage to rebuild it. A ratio this high
      # means the premise is broken, not the data.
      Logger.error(
        "orphan_sweep aborting: missing-point ratio implies a bad authority, not drift. " <>
          "If Qdrant is healthy and this follows a Postgres restore, the divergence is real — " <>
          "re-enqueue with %{\"force\" => true}",
        Metadata.with_category(:error, :oban,
          total_count: length(candidates),
          result: %{scanned: scanned, max_ratio: @max_candidate_ratio}
        )
      )

      0
    else
      # Second look after a grace window, for the write-order race described on
      # `scan_chunk_pages/3`: a note indexing right now legitimately has rows
      # naming points that land moments later.
      grace()

      still_missing =
        case qdrant_points_present(Enum.map(candidates, fn {_note_id, pid} -> pid end)) do
          {:ok, present} ->
            # Re-read Postgres too, not just Qdrant. `commit_index/1` deletes
            # the old points BEFORE the old chunk rows, so a note re-indexed
            # between the scan and here leaves a scanned row whose point is
            # genuinely gone AND whose row is gone — re-asking Qdrant alone
            # confirms "missing" and bills a full re-embed of a note that is
            # correctly indexed. A row that no longer exists proves nothing.
            live_rows = chunk_point_ids(Enum.map(candidates, fn {_note_id, pid} -> pid end))

            Enum.reject(candidates, fn {_note_id, pid} ->
              MapSet.member?(present, pid) or not MapSet.member?(live_rows, pid)
            end)

          {:error, reason} ->
            # Same rule as the first probe: a failed question is not a "yes".
            # Logged rather than swallowed, or a Qdrant that fails only on the
            # confirm pass looks exactly like a clean sweep.
            Logger.error(
              "orphan_sweep confirm probe failed; flagging nothing this tick",
              Metadata.with_category(:error, :oban, reason: Metadata.safe_reason(reason))
            )

            []
        end

      flag_notes_for_reindex(Enum.map(still_missing, fn {note_id, _pid} -> note_id end))
    end
  end

  defp flag_notes_for_reindex([]), do: 0

  defp flag_notes_for_reindex(note_ids) do
    # Chunked against Postgres' 65,535 bind-parameter cap, same as
    # `chunk_point_ids/1`. Candidates are bounded only by the ratio guard, and
    # an unchunked `in ^ids` raises out of a `max_attempts: 1` worker — killing
    # the run before its completion log, daily, with nothing flagged.
    count =
      note_ids
      |> Enum.uniq()
      |> Enum.chunk_every(@id_query_batch)
      |> Enum.reduce(0, fn batch, acc ->
        {n, _} =
          Note
          |> where([n], n.id in ^batch)
          |> Repo.update_all(
            [set: [embed_hash: nil, dense_indexed_hash: nil]],
            skip_tenant_check: true
          )

        acc + n
      end)

    Logger.warning(
      "orphan_sweep flagged notes for re-index: Qdrant is missing their points",
      Metadata.with_category(:warning, :oban, total_count: count)
    )

    count
  end

  # Live notes in live vaults only. A soft-deleted note's points are removed on
  # delete, so its rows would read as stranded and get flagged for a rebuild
  # that then has nothing to rebuild.
  #
  # The VAULT check is load-bearing for a different reason: `ReconcileEmbeddings`
  # joins vaults on `is_nil(deleted_at)`, so a note in a soft-deleted vault can
  # never be rebuilt. Flagging one means re-nulling and re-warning on every tick
  # forever, while inflating the runaway ratio — and `CleanupVault` purges
  # Qdrant points BEFORE its DB transaction, so a restore leaves exactly this
  # shape: live rows in a soft-deleted vault whose points are already gone.
  #
  # skip_tenant_check: cross-tenant by design, same as `chunk_point_ids/1` —
  # RLS would hide exactly the rows this reconciliation exists to check.
  defp chunk_page(after_id) do
    Chunk
    |> join(:inner, [c], n in Note, on: n.id == c.note_id)
    |> join(:inner, [c, n], v in Vault, on: v.id == n.vault_id)
    |> where([c, n, v], is_nil(n.deleted_at) and is_nil(v.deleted_at))
    |> where([c], not is_nil(c.qdrant_point_id))
    |> then(fn q -> if after_id, do: where(q, [c], c.id > ^after_id), else: q end)
    |> order_by([c], asc: c.id)
    |> limit(^chunk_probe_batch())
    |> select([c], {c.id, c.note_id, c.qdrant_point_id})
    |> Repo.all(skip_tenant_check: true)
  end

  # Which of these ids does Qdrant actually hold? `has_id` against the existing
  # scroll endpoint — no new client call.
  #
  # Batched even though the scan already pages, because the confirm pass hands
  # in the whole candidate list at once. `has_id` carries every id in the
  # REQUEST body, so an unbounded call is a multi-megabyte POST, and the answer
  # is used to decide whether to null hashes — a truncated response reads as
  # "these ids are missing" and re-embeds notes whose points are fine.
  defp qdrant_points_present([]), do: {:ok, MapSet.new()}

  defp qdrant_points_present(point_ids) do
    point_ids
    |> Enum.uniq()
    |> Enum.chunk_every(chunk_probe_batch())
    |> Enum.reduce_while({:ok, MapSet.new()}, fn batch, {:ok, acc} ->
      case scroll_ids(batch, nil, MapSet.new()) do
        {:ok, found} -> {:cont, {:ok, MapSet.union(acc, found)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Follows `next_page_offset` rather than trusting one response to carry every
  # match, the same way `scan_pages/3` does. A `limit` is not a guarantee.
  defp scroll_ids(batch, offset, acc) do
    opts = [
      filter: %{must: [%{has_id: batch}]},
      limit: length(batch),
      with_payload: false,
      with_vector: false
    ]

    opts = if offset, do: Keyword.put(opts, :offset, offset), else: opts

    case Qdrant.scroll(opts) do
      {:ok, %{points: points, next_page_offset: next}} ->
        acc =
          points
          |> Enum.map(& &1["id"])
          |> Enum.filter(&is_binary/1)
          |> Enum.into(acc)

        if next, do: scroll_ids(batch, next, acc), else: {:ok, acc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp grace do
    case Application.get_env(:engram, :orphan_sweep_point_grace_fun) do
      fun when is_function(fun, 0) -> fun.()
      _ -> Process.sleep(grace_seconds() * 1000)
    end
  end

  defp grace_seconds,
    do: Application.get_env(:engram, :orphan_sweep_point_grace_seconds, 60)

  # Overridable for the same reason `grace_seconds/0` is: the paging behaviour
  # is only observable across more than one page, and seeding 2,048 chunk rows
  # to prove a cursor advances is a worse test, not a better one.
  defp chunk_probe_batch,
    do: Application.get_env(:engram, :orphan_sweep_chunk_probe_batch, @chunk_probe_batch)

  defp max_missing_candidates,
    do: Application.get_env(:engram, :orphan_sweep_max_missing_candidates, @max_candidates)

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
