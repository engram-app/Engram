defmodule Engram.Vector.ClusterDiff do
  @moduledoc """
  Point-id diff, and optional repair, between two Qdrant clusters (`"old"`,
  `"v2"`), with `chunks.qdrant_point_id` as the authority. Release-safe (no
  Mix): run it from `bin/engram rpc` or a remote shell.

      Engram.Vector.ClusterDiff.run("old", "v2")                 # report only
      Engram.Vector.ClusterDiff.run("old", "v2", repair: true)   # copy missing

  Two walks against the TARGET:

    * missing: every live chunk row (keyset pages of `batch`, default
      `Qdrant.max_ids/0`), probed with `has_id`. A row whose point the target
      lacks is missing. Counted per user.
    * extra: an id-only scroll of the whole target collection, each page
      checked against chunk rows. Skipped with `user_ids:` (a per-user walk
      cannot see points no row names). Report only: once the target is the
      active cluster, OrphanSweep's daily point pass deletes them.

  `repair: true` copies each missing point from the SOURCE (vectors and
  payload as stored, so $0 Voyage), upserting it on the target. A point the
  source lacks too is unrecoverable by copy; `reindex: true` additionally
  flags those notes for re-index (`Indexing.flag_notes_for_rebuild/2`),
  which re-embeds through Voyage (the vector cache, when on, can make it
  free). Re-indexing writes to the ACTIVE cluster, so `reindex: true` is
  refused unless the target is active.

  ## After a flip: what an id diff cannot see

  A node still on the old value after a flip (a lost eviction, up to the
  15s override TTL; a request already in flight, up to ~2 min with Req's
  retries; a node booted with the DB unreachable, on env) writes the OLD
  cluster. Its new point ids read as missing here and are copied. A delete
  leaves an extra on the target (reported; OrphanSweep removes it). But a
  payload or sparse-vector rewrite of an EXISTING id (a rename's repath, a
  reused point's payload refresh, a keyword refresh) leaves the target
  holding the pre-flip version under the same id, and no id diff sees it.
  `since: %DateTime{}` repairs that class: every live note changed since
  then gets `payload_hash` and `keyword_version` cleared, so
  `ReconcileNotePayloads` and the keyword refresh rewrite its points on the
  active cluster. $0 Voyage (payload reads, then writes only where drifted),
  so pick it generously: the flip time minus the indexing backlog, an hour
  is cheap. Refused unless the target is active, as `reindex: true` is.

  Paced: `pause_ms` (default 200) between pages. Run it with the
  Qdrant-writing queues paused: a write that lands on the target between the
  probe and the copy would be overwritten by the source's older point.

  Resumable: every report carries `last_chunk_id`, the keyset cursor of the
  last page the missing walk finished; pass it back as `after:` to resume a
  run that stopped mid-walk. A copy is idempotent, so overlap costs only
  probes.

  Returns `{:ok, report}`, or `{:error, reason}` before any page ran, or
  `{:error, reason, partial_report}` when a page failed mid-walk.
  """

  import Ecto.Query

  alias Engram.Indexing
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vector.PointIds
  alias Engram.Vector.Qdrant
  alias Engram.Workers.ReconcileNotePayloads

  require Logger

  @clusters ["old", "v2"]
  @sample 100

  @spec run(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:error, term(), map()}
  def run(source, target, opts \\ [])

  def run(same, same, _opts), do: {:error, :same_cluster}

  def run(source, target, opts) when source in @clusters and target in @clusters do
    writes_active? = Keyword.get(opts, :reindex, false) or Keyword.has_key?(opts, :since)

    if writes_active? and Qdrant.active_cluster() != target do
      {:error, :target_not_active}
    else
      report = %{
        source: source,
        target: target,
        repair: Keyword.get(opts, :repair, false),
        checked: 0,
        missing: 0,
        missing_by_user: %{},
        missing_sample: [],
        copied: 0,
        unrecoverable: 0,
        flagged_notes: 0,
        requeued_notes: 0,
        last_chunk_id: Keyword.get(opts, :after),
        scanned_target: 0,
        extra: if(Keyword.has_key?(opts, :user_ids), do: nil, else: 0),
        extra_sample: []
      }

      with {:ok, report} <- walk_chunks(report.last_chunk_id, report, opts),
           {:ok, report} <- walk_target(nil, report, opts),
           {:ok, report} <- requeue_heals(report, opts) do
        Logger.info(
          "cluster_diff #{source}->#{target} checked=#{report.checked} missing=#{report.missing} " <>
            "extra=#{inspect(report.extra)} copied=#{report.copied} flagged=#{report.flagged_notes} " <>
            "requeued=#{report.requeued_notes}",
          Metadata.with_category(:info, :data)
        )

        {:ok, report}
      end
    end
  end

  def run(_source, _target, _opts), do: {:error, :unknown_cluster}

  # -- missing on the target ----------------------------------------------------

  defp walk_chunks(after_id, report, opts) do
    batch = Keyword.get(opts, :batch, Qdrant.max_ids())

    case PointIds.chunk_page(after_id, batch, Keyword.take(opts, [:user_ids])) do
      [] ->
        {:ok, report}

      rows ->
        pids = Enum.map(rows, fn {_id, _note, pid, _uid} -> pid end)

        with {:ok, present} <- on(report.target, fn -> PointIds.present(pids, batch) end),
             missing = Enum.reject(rows, fn {_, _, pid, _} -> MapSet.member?(present, pid) end),
             {:ok, report} <- repair(missing, count_missing(report, rows, missing), opts) do
          pause(opts)
          {last_id, _, _, _} = List.last(rows)
          walk_chunks(last_id, %{report | last_chunk_id: last_id}, opts)
        else
          {:error, reason} -> failed(reason, report)
        end
    end
  end

  defp count_missing(report, rows, missing) do
    by_user = Enum.frequencies_by(missing, fn {_, _, _, uid} -> uid end)

    %{
      report
      | checked: report.checked + length(rows),
        missing: report.missing + length(missing),
        missing_by_user: Map.merge(report.missing_by_user, by_user, fn _, a, b -> a + b end),
        missing_sample: sample(report.missing_sample, Enum.map(missing, &elem(&1, 2)))
    }
  end

  defp repair([], report, _opts), do: {:ok, report}

  defp repair(missing, report, opts) do
    if Keyword.get(opts, :repair, false) do
      pids = Enum.map(missing, &elem(&1, 2))

      with {:ok, copied} <- copy(pids, report.source, report.target) do
        lost = Enum.reject(missing, fn {_, _, pid, _} -> MapSet.member?(copied, pid) end)
        flagged = if Keyword.get(opts, :reindex, false), do: reindex(lost), else: 0

        {:ok,
         %{
           report
           | copied: report.copied + MapSet.size(copied),
             unrecoverable: report.unrecoverable + length(lost),
             flagged_notes: report.flagged_notes + flagged
         }}
      end
    else
      {:ok, report}
    end
  end

  # Points as the source stores them, every named vector and the whole
  # payload (the one reader that wants `with_payload: true`: it is a copy).
  defp copy(pids, source, target) do
    pids
    |> Enum.chunk_every(Qdrant.max_write_batch())
    |> Enum.reduce_while({:ok, MapSet.new()}, fn ids, {:ok, acc} ->
      opts = [
        filter: %{must: [%{has_id: ids}]},
        limit: length(ids),
        with_payload: true,
        with_vector: true
      ]

      with {:ok, %{points: points}} <- on(source, fn -> Qdrant.scroll(opts) end),
           points =
             Enum.map(
               points,
               &%{id: &1["id"], vector: &1["vector"], payload: &1["payload"] || %{}}
             ),
           :ok <- upsert(target, points) do
        {:cont, {:ok, Enum.into(points, acc, & &1.id)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp upsert(_target, []), do: :ok
  defp upsert(target, points), do: on(target, fn -> Qdrant.upsert_points(points) end)

  # Only rows that still exist: a note re-indexed since the page was read
  # has new rows and is fine.
  defp reindex([]), do: 0

  defp reindex(lost) do
    live = PointIds.known(Enum.map(lost, &elem(&1, 2)))

    note_ids =
      for {_, note_id, pid, _} <- lost, MapSet.member?(live, pid), uniq: true, do: note_id

    count = Indexing.flag_notes_for_rebuild(note_ids, Repo.maintenance())
    _ = if count > 0, do: Engram.Workers.ReconcileEmbeddings.kick()
    count
  end

  # -- same-id writes since a flip ----------------------------------------------

  defp requeue_heals(report, opts) do
    case Keyword.get(opts, :since) do
      nil ->
        {:ok, report}

      %DateTime{} = since ->
        n = requeue_notes_since(since, Keyword.get(opts, :user_ids))
        _ = if n > 0, do: ReconcileNotePayloads.enqueue_missing()
        {:ok, %{report | requeued_notes: n}}
    end
  end

  # The NULLs `UserDekRotation.hand_points_to_heals/2` sets for the same two
  # heals, cross-tenant on the maintenance pool (RLS would hide the rows).
  defp requeue_notes_since(since, user_ids) do
    repo = Repo.maintenance()

    Repo.cross_tenant(fn ->
      {n, _} =
        from(n in Note,
          where: n.kind == "note" and is_nil(n.deleted_at) and n.updated_at >= ^since
        )
        |> then(fn q -> if user_ids, do: where(q, [n], n.user_id in ^user_ids), else: q end)
        |> repo.update_all(set: [payload_hash: nil, keyword_version: nil])

      n
    end)
  end

  # -- extra on the target ------------------------------------------------------

  defp walk_target(_offset, %{extra: nil} = report, _opts), do: {:ok, report}

  defp walk_target(offset, report, opts) do
    scroll = [filter: %{}, limit: Qdrant.max_page(), with_payload: false, with_vector: false]
    scroll = if offset, do: Keyword.put(scroll, :offset, offset), else: scroll

    case on(report.target, fn -> Qdrant.scroll(scroll) end) do
      {:ok, %{points: points, next_page_offset: next}} ->
        ids = points |> Enum.map(& &1["id"]) |> Enum.filter(&is_binary/1)
        known = PointIds.known(ids)
        extra = Enum.reject(ids, &MapSet.member?(known, &1))

        report = %{
          report
          | scanned_target: report.scanned_target + length(ids),
            extra: report.extra + length(extra),
            extra_sample: sample(report.extra_sample, extra)
        }

        if next do
          pause(opts)
          walk_target(next, report, opts)
        else
          {:ok, report}
        end

      {:error, reason} ->
        failed(reason, report)
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp on(cluster, fun), do: Qdrant.with_cluster(cluster, fun)

  defp sample(acc, more), do: Enum.take(acc ++ more, @sample)

  defp pause(opts), do: Process.sleep(Keyword.get(opts, :pause_ms, 200))

  defp failed(reason, report) do
    Logger.error(
      "cluster_diff stopped mid-walk",
      Metadata.with_category(:error, :data, reason: Metadata.safe_reason(reason))
    )

    {:error, reason, report}
  end
end
