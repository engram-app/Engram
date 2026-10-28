defmodule Engram.DataMigrations.NoteIndexState do
  @moduledoc """
  Fills `note_index_state` for notes written before the
  `notes_sync_index_state` trigger existed (migration 20261026000000). Every
  later write fills it itself, from any release's code, so this only
  catches up.

  The work is the trigger's own SQL function (`note_index_state_sync`), in
  fill-only mode: a row the trigger already wrote is newer than this pass's
  snapshot and is never replaced. It writes no `notes` row, so the notes
  table (24 indexes, measured 2026-10-24) takes no extra versions.

  Then the chunk counters (`points`, `len_rows`, `len_sum`): every note
  whose counters differ from its `chunks` rows is re-counted under its
  `notes` row lock (`FOR UPDATE SKIP LOCKED`, the lock `commit_index` holds
  while it writes chunks), so the count cannot race a pass on that note.
  This is both the backfill and the self-heal: done (`counted?/0`) gates
  the vault and user sums, and the daily re-verify re-counts whatever a
  previous-release writer (a rolling deploy, a rollback) left behind.

  Discovery is one maintenance-pool query per batch on SaaS, a per-user
  loop on self-host (`TenantScan`), like `NoteSplit`. The embed columns are
  not read yet.
  """
  @behaviour Engram.DataMigration

  alias Engram.Backfill.TenantScan
  alias Engram.Indexing.ChunkRows
  alias Engram.Logger.Metadata
  alias Engram.Repo

  require Logger

  # Rows per keyset window. A recount query scans exactly this many notes
  # (one chunk-index probe each), whatever the drift density.
  @batch 1_000
  # 200 windows = 200k notes per phase per pass, above the largest vault set
  # seen (70k `notes` rows on prod, 2026-10-27).
  @max_batches 200

  @impl true
  def name, do: "note_index_state"

  @impl true
  def version, do: 1

  @impl true
  def reverify?, do: true

  @impl true
  def run_pass, do: run_pass([])

  @doc """
  True once every note's chunk counters were counted: the vault and user
  sums over `note_index_state` may replace the `count(*)` / `avg` over
  `chunks`.
  """
  @spec counted?() :: boolean()
  def counted?, do: Engram.DataMigrations.done?(name(), version())

  @doc false
  # `batch:` overrides the window size (tests page over a few rows).
  #
  # The recount phase walks EVERY note once, in id windows, so a pass that
  # fixed nothing has by construction seen no missing row and no drifted
  # counter: that is the done check, there is no separate "anything left?"
  # scan. (The old one re-ran the full correlated chunk count over all notes
  # in one statement and tripped DBConnection's 15 s timeout on prod.)
  # Per-query timeouts for the maintenance pool live in
  # `Engram.RuntimeConfig.maintenance_timeout/0`, applied once in runtime.exs.
  def run_pass(opts) do
    batch = Keyword.get(opts, :batch, @batch)

    {filled, recounted, capped?} =
      case Repo.maintenance() do
        Repo ->
          TenantScan.user_ids()
          |> Enum.map(fn user_id ->
            {f, cf} =
              batches(batch, fn after_id ->
                Repo.with_tenant!(user_id, fn -> fill(Repo, user_id, after_id, batch) end)
              end)

            {r, cr} =
              batches(batch, fn after_id ->
                Repo.with_tenant!(user_id, fn -> recount(Repo, user_id, after_id, batch) end)
              end)

            {f, r, cf or cr}
          end)
          |> Enum.reduce({0, 0, false}, fn {f, r, c}, {af, ar, ac} ->
            {af + f, ar + r, ac or c}
          end)

        maintenance ->
          {f, cf} = batches(batch, &fill(maintenance, nil, &1, batch))

          {r, cr} =
            batches(batch, fn after_id ->
              {:ok, step} =
                maintenance.transaction(fn -> recount(maintenance, nil, after_id, batch) end)

              step
            end)

          {f, r, cf or cr}
      end

    # Counts only, never ids (tenant data).
    Logger.info(
      "note_index_state pass",
      Metadata.with_category(:info, :oban,
        migration: name(),
        filled: filled,
        recounted: recounted,
        hit_batch_cap: capped?
      )
    )

    if filled + recounted > 0 or capped?, do: {:more, rows: filled + recounted}, else: :done
  end

  # `step.(after_id)` returns `{scanned, last_id, hits}`: a window short of
  # `batch` is the end of the walk. Returns `{hits, hit_cap?}`.
  defp batches(batch, step, after_id \\ nil, hits \\ 0, rounds \\ 0)
  defp batches(_batch, _step, _after_id, hits, @max_batches), do: {hits, true}

  defp batches(batch, step, after_id, hits, rounds) do
    case step.(after_id) do
      {scanned, _last, h} when scanned < batch -> {hits + h, false}
      {_scanned, last, h} -> batches(batch, step, last, hits + h, rounds + 1)
    end
  end

  # Filled notes. Lowercase uuid strings sort as their bytes, so the max id
  # is the keyset.
  defp fill(repo, user_id, after_id, batch) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT n.id::text, note_index_state_sync(n, false) FROM notes n
        WHERE n.kind = 'note'
          AND ($1::uuid IS NULL OR n.user_id = $1::uuid)
          AND NOT EXISTS (SELECT 1 FROM note_index_state s WHERE s.note_id = n.id)
          AND ($2::uuid IS NULL OR n.id > $2::uuid)
        ORDER BY n.id LIMIT $3
        """,
        [dump(user_id), dump(after_id), batch]
      )

    ids = Enum.map(rows, &hd/1)
    {length(ids), List.last(ids), length(ids)}
  end

  # Inside a transaction: scans one id window of `batch` notes (one
  # `chunks (note_id, position)` index probe each), locks the drifted ones
  # (skipping any a writer holds; a later pass takes them), then counts
  # them in a new statement, so the count sees every chunk write that
  # committed before the lock. Skipped notes still count as hits, so the
  # pass stays open for them.
  defp recount(repo, user_id, after_id, batch) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT w.id::text,
               CASE WHEN s.note_id IS NULL THEN false ELSE
                 ROW(s.points, s.len_rows, s.len_sum) IS DISTINCT FROM (
                   SELECT ROW(count(*)::int, count(c.token_count)::int,
                              coalesce(sum(c.token_count), 0)::bigint)
                   FROM chunks c WHERE c.note_id = w.id)
               END
        FROM (SELECT n.id FROM notes n
              WHERE n.kind = 'note'
                AND ($1::uuid IS NULL OR n.user_id = $1::uuid)
                AND ($2::uuid IS NULL OR n.id > $2::uuid)
              ORDER BY n.id LIMIT $3) w
        LEFT JOIN note_index_state s ON s.note_id = w.id
        ORDER BY w.id
        """,
        [dump(user_id), dump(after_id), batch]
      )

    drifted = for [id, true] <- rows, do: id
    locked = ChunkRows.lock_notes!(drifted, repo: repo, skip_locked: true)
    _ = ChunkRows.recount!(locked, repo)
    {length(rows), rows |> List.last() |> then(&(&1 && hd(&1))), length(drifted)}
  end

  defp dump(nil), do: nil
  defp dump(id), do: Ecto.UUID.dump!(id)
end
