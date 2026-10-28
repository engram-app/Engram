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

  Discovery walks `notes` in fixed id windows (`Engram.Backfill.IdWindows`):
  one fleet walk on the maintenance pool on SaaS, a per-user walk on
  self-host, like `NoteSplit`. Each statement reads one window, never "the
  next 1,000 notes that need work", which walked most of the table once
  matches were rare and hit the 15 s query timeout in prod (#2276). A pass
  that walks every window and fixes nothing is done; no separate "anything
  left?" scan. The embed columns are not read yet.
  """
  @behaviour Engram.DataMigration

  alias Engram.Backfill.IdWindows
  alias Engram.Indexing.ChunkRows
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note

  require Logger

  # Notes per id window. A drift scan probes exactly this many notes (one
  # chunk-index probe each), whatever the drift density.
  @batch 1_000

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
  # `batch:` overrides the window size (tests walk a few rows), `budget_ms:`
  # the pass's time budget (`IdWindows.heal_pass/3`).
  def run_pass(opts) do
    result =
      IdWindows.heal_pass(Note, &heal/2,
        batch_size: Keyword.get(opts, :batch, @batch),
        budget_ms: Keyword.get(opts, :budget_ms, IdWindows.pass_budget_ms())
      )

    # Counts only, never ids (tenant data). `rows` counts notes filled, and
    # notes seen with a missing row or wrong counters, including any a writer
    # held locked.
    {rows, hit_budget} =
      case result do
        :done -> {0, false}
        {:more, found} -> {found[:rows], Keyword.get(found, :hit_budget, false)}
      end

    Logger.info(
      "note_index_state pass",
      Metadata.with_category(:info, :oban, migration: name(), rows: rows, hit_budget: hit_budget)
    )

    result
  end

  # One window, inside its transaction: fill the missing rows, then lock the
  # drifted notes (skipping any a writer holds; a later pass takes them) and
  # re-count them in a new statement, so the count sees every chunk write
  # that committed before the lock. A skipped note, or one whose row went
  # missing after the fill, keeps the pass open.
  defp heal(ids, %{repo: repo}) do
    keys = Enum.map(ids, &Ecto.UUID.dump!/1)
    filled = fill(repo, keys)
    {drifted, missing} = drifted(repo, keys)
    locked = ChunkRows.lock_notes!(drifted, repo: repo, skip_locked: true)
    _ = ChunkRows.recount!(locked, repo)
    {filled + length(drifted) + missing, missing > 0 or length(locked) < length(drifted)}
  end

  # The trigger's own function, fill-only, for the window's notes with no
  # state row.
  defp fill(repo, keys) do
    %{num_rows: n} =
      repo.query!(
        """
        SELECT note_index_state_sync(n, false) FROM notes n
        WHERE n.id = ANY($1::uuid[]) AND n.kind = 'note'
          AND NOT EXISTS (SELECT 1 FROM note_index_state s WHERE s.note_id = n.id)
        """,
        [keys]
      )

    n
  end

  # The window's notes whose counters differ from their chunk rows (one
  # index probe of `chunks (note_id, position)` per note), and how many have
  # no state row (the fill owns those; one gone since is a hit).
  defp drifted(repo, keys) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT n.id::text,
               CASE WHEN s.note_id IS NULL THEN 'missing'
                    WHEN ROW(s.points, s.len_rows, s.len_sum) IS DISTINCT FROM (
                           SELECT ROW(count(*)::int, count(c.token_count)::int,
                                      coalesce(sum(c.token_count), 0)::bigint)
                           FROM chunks c WHERE c.note_id = n.id)
                    THEN 'drifted' ELSE 'ok' END
        FROM notes n LEFT JOIN note_index_state s ON s.note_id = n.id
        WHERE n.id = ANY($1::uuid[]) AND n.kind = 'note'
        """,
        [keys]
      )

    {for([id, "drifted"] <- rows, do: id), Enum.count(rows, &match?([_, "missing"], &1))}
  end
end
