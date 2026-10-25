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
  Discovery is one maintenance-pool query per batch on SaaS, a per-user loop
  on self-host (`TenantScan`).

  Readers keep using the old columns; nothing gates on this yet. Re-verifies
  daily, so a row a trigger somehow missed (a restore from an old dump) is
  caught.
  """
  @behaviour Engram.DataMigration

  import Ecto.Query

  alias Engram.Backfill.TenantScan
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note
  alias Engram.Notes.NoteBody
  alias Engram.Repo

  require Logger

  @batch 1_000
  # Rows per pass: a pass is one bounded slice; the next run takes the rest.
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
  # `batch:` overrides the batch size (tests page over a few rows).
  def run_pass(opts) do
    batch = Keyword.get(opts, :batch, @batch)

    {touched, left?, drift} =
      case Repo.maintenance() do
        Repo ->
          users = TenantScan.user_ids()

          touched =
            users
            |> Enum.map(fn user_id ->
              batches(batch, fn after_id ->
                Repo.with_tenant!(user_id, fn ->
                  touch(Repo, needing(user_id, after_id, batch))
                end)
              end)
            end)
            |> Enum.sum()

          left? = fn ->
            Enum.any?(users, fn user_id ->
              Repo.with_tenant!(user_id, fn -> left?(Repo, user_id) end)
            end)
          end

          drift = fn ->
            Enum.each(users, fn user_id ->
              Repo.with_tenant!(user_id, fn -> report_drift(Repo, user_id) end)
            end)
          end

          {touched, left?, drift}

        maintenance ->
          {batches(batch, fn after_id -> touch(maintenance, needing(nil, after_id, batch)) end),
           fn -> left?(maintenance, nil) end, fn -> report_drift(maintenance, nil) end}
      end

    # SKIP LOCKED passes over a row a writer holds, so a pass that touched
    # nothing has not proven the table clean. Only an unlocked look that finds
    # no row left closes the ledger; until then the ids stay off.
    cond do
      touched > 0 -> {:more, rows: touched}
      left?.() -> {:more, rows: 0}
      true -> tap(:done, fn _ -> drift.() end)
    end
  end

  # Runs `step` from an id keyset until a batch comes back short or the pass's
  # budget is spent, so each batch reads on from the last instead of rescanning
  # the rows already fixed.
  defp batches(batch, step, after_id \\ nil, n \\ 0, rounds \\ 0)
  defp batches(_batch, _step, _after_id, n, @max_batches), do: n

  defp batches(batch, step, after_id, n, rounds) do
    case step.(after_id) do
      ids when length(ids) < batch -> n + length(ids)
      ids -> batches(batch, step, Enum.max(ids), n + length(ids), rounds + 1)
    end
  end

  # In id order with SKIP LOCKED: one batch locks up to 1,000 rows across
  # tenants, and a user's multi-row write (a folder rename, a batch push)
  # locks in its own order. A row a writer holds is skipped, not waited on;
  # that write fires the triggers itself, and a later pass takes any it left.
  defp needing(user_id, after_id, batch) do
    q =
      from(n in unfixed(user_id),
        order_by: field(n, :id),
        select: field(n, :id),
        limit: ^batch,
        lock: "FOR UPDATE SKIP LOCKED"
      )

    if after_id, do: where(q, [n], field(n, :id) > type(^after_id, Ecto.UUID)), else: q
  end

  # Readers take the body from `note_bodies` (`Engram.Notes.NoteBody`), so a
  # body row that disagrees with its notes row would be served. The trigger
  # rewrites a body column only when its nonce changes, so a write that
  # changed a ciphertext but kept its nonce (no writer does; a restore or a
  # hand edit could) leaves the body stale. A pass that closes the ledger
  # (the last catch-up pass, and every daily re-verify) compares the two
  # (`NoteBody.drift/0`, slices only), in id-keyset batches so no single
  # snapshot spans the table.
  #
  # REPORT ONLY: counted (`[:engram, :note_split, :body_drift]`) and logged
  # with the note ids, never repaired, and it does not reopen the ledger
  # (the Keys ids come from the core columns, not the bodies). The release
  # that stops writing the notes body columns runs beside this one and can
  # roll back to it; there the BODY is the newer side, so a repair that
  # trusted `notes` would overwrite it with stale or NULL data. A non-zero
  # count is an alert and a runbook step, and contract may not drop the
  # notes columns while it is non-zero.
  @drift_batch 5_000
  @drift_logged_ids 20

  defp report_drift(repo, user_id, after_id \\ nil, found \\ []) do
    q =
      from(n in Note, where: n.kind == "note", order_by: n.id, limit: @drift_batch)
      |> NoteBody.join()
      |> where([_n, note_body: b], not is_nil(b.note_id))
      |> select([n], %{id: n.id})
      |> select_merge(^%{drift: NoteBody.drift()})

    q = if user_id, do: where(q, [n], field(n, :user_id) == type(^user_id, Ecto.UUID)), else: q
    q = if after_id, do: where(q, [n], n.id > ^after_id), else: q

    rows = repo.all(q)
    found = for(%{id: id, drift: true} <- rows, do: id) ++ found

    if length(rows) == @drift_batch,
      do: report_drift(repo, user_id, List.last(rows).id, found),
      else: emit_drift(found, user_id)
  end

  defp emit_drift(ids, user_id) do
    :telemetry.execute([:engram, :note_split, :body_drift], %{count: length(ids)}, %{})

    if ids != [] do
      Logger.warning(
        "note_split: #{length(ids)} note body row(s) disagree with notes (not repaired)",
        Metadata.with_category(:warning, :sync,
          user_id: user_id,
          count: length(ids),
          note_ids: Enum.take(ids, @drift_logged_ids)
        )
      )
    end

    length(ids)
  end

  # Any row still needing work, locked or not: no lock, so a held row counts.
  defp left?(repo, user_id), do: repo.exists?(unfixed(user_id))

  defp unfixed(user_id) do
    q =
      from(n in "notes",
        as: :n,
        where:
          is_nil(field(n, :is_folder)) or
            (field(n, :kind) == "note" and
               not exists(
                 from(b in "note_bodies", where: b.note_id == parent_as(:n).id, select: 1)
               ))
      )

    if user_id, do: where(q, [n], field(n, :user_id) == type(^user_id, Ecto.UUID)), else: q
  end

  # ONE statement: the ids subquery and the touch. Returns the touched ids;
  # lowercase uuid strings sort as their bytes do, so the max is the keyset.
  #
  # `= ANY(ARRAY(...))`, not `IN (...)`: Postgres may plan an IN subquery as a
  # semi-join it RESCANS per outer row, and a rescan of LIMIT .. FOR UPDATE
  # SKIP LOCKED skips the rows this statement already updated and returns the
  # next ones, so one batch touched more than its limit and the keyset jumped
  # past rows. ARRAY(...) is an InitPlan, evaluated exactly once.
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
