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
  # The walk restarts from the first note every pass (no persisted cursor), so
  # it is bounded by time, not by a window count: a count cap would stall the
  # tail forever once the table outgrew it. A clean window is milliseconds, so
  # this reaches far past any real table; the Oban job timeout is 30 min.
  @budget_ms 240_000

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
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :budget_ms, @budget_ms)

    {{filled, over_fill}, {drifted, over_recount}} =
      case Repo.maintenance() do
        Repo ->
          TenantScan.user_ids()
          |> Enum.map(fn user_id ->
            {batches(batch, deadline, fn after_id ->
               Repo.with_tenant!(user_id, fn -> fill(Repo, user_id, after_id, batch) end)
             end),
             batches(batch, deadline, fn after_id ->
               Repo.with_tenant!(user_id, fn -> recount(Repo, user_id, after_id, batch) end)
             end)}
          end)
          |> Enum.reduce({{0, false}, {0, false}}, fn {{f, cf}, {r, cr}},
                                                      {{af, acf}, {ar, acr}} ->
            {{af + f, acf or cf}, {ar + r, acr or cr}}
          end)

        maintenance ->
          {batches(batch, deadline, &fill(maintenance, nil, &1, batch)),
           batches(batch, deadline, fn after_id ->
             {:ok, step} =
               maintenance.transaction(fn -> recount(maintenance, nil, after_id, batch) end)

             step
           end)}
      end

    over_budget? = over_fill or over_recount

    # Counts only, never ids (tenant data). `drifted` counts notes seen with a
    # missing row or wrong counters, including any a writer held locked.
    Logger.info(
      "note_index_state pass",
      Metadata.with_category(:info, :oban,
        migration: name(),
        filled: filled,
        drifted: drifted,
        hit_budget: over_budget?
      )
    )

    if filled + drifted > 0 or over_budget?,
      do: {:more, rows: filled + drifted},
      else: :done
  end

  # `step.(after_id)` returns `{scanned, last_id, hits}`: a window short of
  # `batch` is the end of the walk. Returns `{hits, out_of_time?}`.
  defp batches(batch, deadline, step, after_id \\ nil, hits \\ 0) do
    if System.monotonic_time(:millisecond) > deadline do
      {hits, true}
    else
      case step.(after_id) do
        {scanned, _last, h} when scanned < batch -> {hits + h, false}
        {_scanned, last, h} -> batches(batch, deadline, step, last, hits + h)
      end
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
               CASE WHEN s.note_id IS NULL THEN 'missing'
                    WHEN ROW(s.points, s.len_rows, s.len_sum) IS DISTINCT FROM (
                           SELECT ROW(count(*)::int, count(c.token_count)::int,
                                      coalesce(sum(c.token_count), 0)::bigint)
                           FROM chunks c WHERE c.note_id = w.id)
                    THEN 'drifted' ELSE 'ok' END
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

    drifted = for [id, "drifted"] <- rows, do: id
    # A missing row cannot be counted here (fill owns it): it is only a hit,
    # which keeps the pass open until the next fill.
    missing = Enum.count(rows, &match?([_, "missing"], &1))
    locked = ChunkRows.lock_notes!(drifted, repo: repo, skip_locked: true)
    _ = ChunkRows.recount!(locked, repo)
    {length(rows), rows |> List.last() |> then(&(&1 && hd(&1))), length(drifted) + missing}
  end

  defp dump(nil), do: nil
  defp dump(id), do: Ecto.UUID.dump!(id)
end
