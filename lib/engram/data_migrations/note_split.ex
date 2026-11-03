defmodule Engram.DataMigrations.NoteSplit do
  @moduledoc """
  Fills wave 3's narrow `notes` columns and `note_bodies` for rows written
  before the `notes_derive_core_keys` / `notes_sync_body` triggers existed
  (migration 20261021110200; `notes_sync_body` was dropped in
  20261103120000). Every later write fills them itself, so this only
  catches up.

  The core columns are the trigger's own work: a pass touches `kind`
  (`SET kind = kind`), which `notes_derive_core_keys` lists, so each row is
  derived by exactly the code that derives new writes. A missing body row is
  inserted by `NoteBody.sync!/3`, the app's one body writer. `seq` and
  `updated_at` are untouched: no sync feed or cache sees a change.

  A row needs work when its derived columns were never set (`is_folder` is
  NULL; the trigger always sets it) or it is a note with no body row.
  Discovery walks `notes` in fixed id windows (`Engram.Backfill.IdWindows`):
  one fleet walk on the maintenance pool on SaaS, a per-user walk on
  self-host. Each statement reads one window (#2276).

  Readers keep using the old columns; nothing gates on this yet.

  Not re-verified once done (`reverify?/0` stays `false`). The daily re-verify
  walked every notes window and de-TOASTed both bodies of every note for the
  drift report (prod 2026-10-28..11-02: ~95 windows a day, ~700 ms and 1.6-1.9k
  disk reads each, evicting the hot set) and did not reopen it once in 14 days
  of prod logs. It has nothing to find: the triggers are in the database, so every INSERT and every write of a
  source column fills the row, from any release's code, during a rolling
  deploy and after a rollback alike; no code writes a derived column or
  deletes a `note_bodies` row (the FK cascades with its note). A full restore
  brings this ledger row back from the same dump as the rows it vouches for.
  What remains is a write with triggers disabled (`session_replication_role
  = replica`, a data-only `pg_restore --disable-triggers`): an operator who
  does that reopens the ledger cluster-wide (`DataMigrations.reopen/2`,
  runbook in `docs/context/data-migrations-ledger.md`), and the next hourly
  pass heals it.
  """
  @behaviour Engram.DataMigration

  import Ecto.Query

  alias Engram.Backfill.IdWindows
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note
  alias Engram.Notes.NoteBody

  require Logger

  @batch 1_000
  # Rows fixed per pass, in windows: a pass is one bounded slice of writes;
  # the next run takes the rest.
  @max_batches 50

  @impl true
  def name, do: "note_split"

  @impl true
  def version, do: 1

  @impl true
  def run_pass, do: run_pass([])

  @doc false
  # `batch:` overrides the window size (tests walk a few rows).
  def run_pass(opts) do
    batch = Keyword.get(opts, :batch, @batch)

    # SKIP LOCKED passes over a row a writer holds, so a window that touched
    # less than it matched has not proven the table clean: `heal/2` reports
    # the row as left and the pass stays open. Only a walk over every window
    # that finds no row left closes the ledger; until then the ids stay off.
    case IdWindows.heal_pass(name(), Note, &heal/2,
           batch_size: batch,
           max_fixed: @max_batches * batch
         ) do
      :done -> tap(:done, fn _ -> safe_drift(fn -> report_drift(batch) end) end)
      more -> more
    end
  end

  # One window: touch what needs work, then look (no lock) for a row the
  # touch skipped because a writer held it.
  defp heal(ids, %{repo: repo}) do
    touched = touch(repo, needing(ids))
    # A missing body row, written by this pass. Present rows are left as
    # they are.
    _ = NoteBody.sync!(touched, [], repo: repo)
    left? = repo.exists?(where(unfixed(), [n], field(n, :id) in type(^ids, {:array, Ecto.UUID})))
    {length(touched), left?}
  end

  # With SKIP LOCKED: one window locks up to 1,000 rows across tenants, and
  # a user's multi-row write (a folder rename, a batch push) locks in its own
  # order. A row a writer holds is skipped, not waited on; that write fires
  # the triggers itself, and a later pass takes any it left.
  defp needing(ids) do
    from(n in unfixed(),
      where: field(n, :id) in type(^ids, {:array, Ecto.UUID}),
      order_by: field(n, :id),
      select: field(n, :id),
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  # Readers take the body from `note_bodies` (`Engram.Notes.NoteBody`), so a
  # body row that disagrees with its notes row would be served. The trigger
  # rewrites a body column only when its nonce changes, so a write that
  # changed a ciphertext but kept its nonce (no writer does; a restore or a
  # hand edit could) leaves the body stale. A pass that closes the ledger
  # (the last catch-up pass after a version bump or a reopen) compares the two
  # (`NoteBody.drift_ids/2`, slices only), in id windows so no single
  # statement or snapshot spans the table.
  #
  # REPORT ONLY: counted (`[:engram, :note_split, :body_drift]`) and logged
  # with the note ids, never repaired, and it does not reopen the ledger
  # (the Keys ids come from the core columns, not the bodies). The release
  # that stops writing the notes body columns runs beside this one and can
  # roll back to it; there the BODY is the newer side, so a repair that
  # trusted `notes` would overwrite it with stale or NULL data. A non-zero
  # count is an alert and a runbook step, and contract may not drop the
  # notes columns while it is non-zero.
  # A drift scan that raises (a statement timeout, a pool exit) is logged
  # and counted (`[:engram, :note_split, :body_drift_error]`) and never
  # changes the pass outcome: a pass that closes the ledger stays `:done`,
  # or a report would keep the Keys ids off.
  defp safe_drift(drift) do
    drift.()
  rescue
    e -> drift_failed(e)
  catch
    :exit, reason -> drift_failed(reason)
  end

  defp drift_failed(reason) do
    :telemetry.execute([:engram, :note_split, :body_drift_error], %{count: 1}, %{})

    Logger.error(
      "note_split: body drift scan failed",
      Metadata.with_category(:error, :sync, reason: Metadata.safe_reason(reason))
    )
  end

  @drift_logged_ids 20

  defp report_drift(batch) do
    drift_fault()

    {:ok, found} =
      IdWindows.reduce_all(
        Note,
        [],
        fn ids, %{repo: repo}, found -> {:cont, drift_ids(repo, ids) ++ found} end,
        batch_size: batch
      )

    emit_drift(found)
  end

  @doc false
  # The notes among `ids` whose body row drifted (`NoteBody.drift_ids/2`), or
  # whose body row is owned by another user: `NoteBody.join/1` matches the
  # owner too (R5), so every read treats such a row as missing and falls
  # back to the notes columns. Reported like any other drift, never repaired.
  def drift_ids(repo, ids), do: NoteBody.drift_ids(repo, ids)

  # Test-only fault seam: nil outside tests.
  defp drift_fault do
    case Application.get_env(:engram, :note_split_drift_fault) do
      nil -> :ok
      fun when is_function(fun, 0) -> fun.()
    end
  end

  defp emit_drift(ids) do
    :telemetry.execute([:engram, :note_split, :body_drift], %{count: length(ids)}, %{})

    if ids != [] do
      Logger.warning(
        "note_split: #{length(ids)} note body row(s) disagree with notes (not repaired)",
        Metadata.with_category(:warning, :sync,
          count: length(ids),
          note_ids: Enum.take(ids, @drift_logged_ids)
        )
      )
    end

    length(ids)
  end

  @doc false
  # The notes among `ids` the triggers should have filled but did not (the
  # `unfixed/0` predicate). For `Engram.Bookkeeping.Canary`.
  def unfixed_ids(repo, ids) do
    repo.all(
      from(n in unfixed(),
        where: field(n, :id) in type(^ids, {:array, Ecto.UUID}),
        select: type(field(n, :id), Ecto.UUID)
      )
    )
  end

  defp unfixed do
    from(n in "notes",
      as: :n,
      where:
        is_nil(field(n, :is_folder)) or
          (field(n, :kind) == "note" and
             not exists(from(b in "note_bodies", where: b.note_id == parent_as(:n).id, select: 1)))
    )
  end

  # ONE statement: the ids subquery and the touch. Returns the touched ids.
  #
  # `= ANY(ARRAY(...))`, not `IN (...)`: Postgres may plan an IN subquery as a
  # semi-join it RESCANS per outer row, and a rescan of LIMIT .. FOR UPDATE
  # SKIP LOCKED skips the rows this statement already updated and returns the
  # next ones, so one batch touched more than its limit and skipped rows.
  # ARRAY(...) is an InitPlan, evaluated exactly once.
  defp touch(repo, needing) do
    {_count, ids} =
      repo.update_all(
        from(n in Note,
          where: fragment("? = ANY(ARRAY(?))", n.id, subquery(needing)),
          update: [set: [kind: fragment("kind")]],
          select: n.id
        ),
        []
      )

    ids
  end
end
