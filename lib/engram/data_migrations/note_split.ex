defmodule Engram.DataMigrations.NoteSplit do
  @moduledoc """
  Fills wave 3's narrow `notes` columns and `note_bodies` for rows written
  before the `notes_derive_core_keys` / `notes_sync_body` triggers existed
  (migration 20261021110200). Every later write fills them itself, from any
  release's code, so this only catches up.

  The work is the triggers' own: a pass touches `kind` (`SET kind = kind`),
  which both triggers list, so each row is derived by exactly the code that
  derives new writes. `seq` and `updated_at` are untouched: no sync feed or
  cache sees a change.

  A row needs work when its derived columns were never set (`is_folder` is
  NULL; the trigger always sets it) or it is a note with no body row.
  Discovery walks `notes` in fixed id windows (`Engram.Backfill.IdWindows`):
  one fleet walk on the maintenance pool on SaaS, a per-user walk on
  self-host. Each statement reads one window (#2276).

  Readers keep using the old columns; nothing gates on this yet. Re-verifies
  daily, so a row a trigger somehow missed (a restore from an old dump) is
  caught.
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
  def reverify?, do: true

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
    case IdWindows.heal_pass(Note, &heal/2, batch_size: batch, max_fixed: @max_batches * batch) do
      :done -> tap(:done, fn _ -> safe_drift(fn -> report_drift(batch) end) end)
      more -> more
    end
  end

  # One window: touch what needs work, then look (no lock) for a row the
  # touch skipped because a writer held it.
  defp heal(ids, %{repo: repo}) do
    touched = touch(repo, needing(ids))
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
  # (the last catch-up pass, and every daily re-verify) compares the two
  # (`NoteBody.drift/0`, slices only), in id windows so no single
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
        fn ids, %{repo: repo}, found ->
          rows =
            from(n in Note, where: n.kind == "note" and n.id in ^ids)
            |> NoteBody.join()
            |> where([_n, note_body: b], not is_nil(b.note_id))
            |> select([n], %{id: n.id})
            |> select_merge(^%{drift: NoteBody.drift()})
            |> repo.all()

          {:cont, for(%{id: id, drift: true} <- rows, do: id) ++ found}
        end,
        batch_size: batch
      )

    emit_drift(found)
  end

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
