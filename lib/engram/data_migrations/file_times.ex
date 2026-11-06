defmodule Engram.DataMigrations.FileTimes do
  @moduledoc """
  R25 migrate-data: fills the `*_at` timestamptz twins (migration
  20261105140000) from the epoch doubles: `notes.mtime_at` / `ctime_at`,
  `attachments.mtime_at`, `attachment_uploads.mtime_at`.

  A row is work when its `*_at` differs from `Engram.FileTime.normalize/1`
  of its double, NULL or not: a release before expand, running during a
  rollout or after a rollback, moves a double without its twin and leaves a
  stale non-NULL value. Values come from `FileTime` (never `to_timestamp`,
  which rounds), the same normalizer every writer uses. Readers serve the
  twin since the R25 read switch (`FileTime.epoch/2`, the double only while
  the twin is NULL), so this backfill and `FileTime.put_at/3` (which heals
  the twin on every write) are what make the served value right. It was
  confirmed done in prod before the switch shipped.

  Each table is its own `IdWindows.heal_pass/4` walk (cursor
  `file_times:<table>`). A table whose walk came back clean is not walked
  again on this node while another is still open; the ledger is done once
  all three have walked clean, and that memory is dropped. Each window reads
  only the id, user, doubles and twins of its rows by primary key, then
  writes only the drifted rows (`FOR NO KEY UPDATE SKIP LOCKED`, which does
  not block the foreign-key checks of child inserts, and a compare-and-set
  on the double), so a concurrent writer wins and its row counts as left.

  Per table per pass it logs `file times repaired` (the guard against a
  writer that skips the twin: after the first full walk it should stay
  silent) and `file_time_out_of_range` with the count of legacy
  out-of-range doubles it set NULL (written once, so a later walk is quiet).
  Only `*_at` columns are written: no trigger fires (every `notes` trigger
  is `UPDATE OF` other columns), `updated_at`/`seq` never move, no fan-out.

  A fixed note with a millisecond double served a different `up`/`cr` before
  this release, so its points hold a stale payload: its `payload_hash` is
  NULLed (only those notes) and `ReconcileNotePayloads` is queued for its
  user, which rewrites only unstamped notes' points.

  v2 re-walks for the rounding fix (`version/0`). `enabled?/0` is the
  `file_times_backfill` service override (default on). Not re-verified;
  contract bumps `version/0` to take one last clean walk before dropping
  the doubles.
  """
  @behaviour Engram.DataMigration

  import Ecto.Query

  alias Engram.Backfill.IdWindows
  alias Engram.Backfill.TenantScan
  alias Engram.FileTime
  alias Engram.Logger.Metadata
  alias Engram.Workers.ReconcileNotePayloads

  require Logger

  # Small windows and a per-pass write cap: a `notes` row version may be
  # non-HOT (every index gets an entry) on a 4 GB RDS that has swapped.
  @batch 200
  @max_fixed 10_000

  @tables [
    {Engram.Notes.Note, [mtime: :mtime_at, ctime: :ctime_at]},
    {Engram.Attachments.Attachment, [mtime: :mtime_at]},
    {Engram.Attachments.Upload, [mtime: :mtime_at]}
  ]

  # Node-local: the tables that walked clean in the current run of passes.
  @clean {__MODULE__, :clean}

  @impl true
  def name, do: "file_times"

  # v2: `FileTime.to_at/1` rounds to the microsecond (0.74 and 0.75
  # floored, leaving about a quarter of millisecond values dated 2004-2005
  # or past 2038-01-19 one microsecond low). The re-walk rewrites them.
  @impl true
  def version, do: 2

  @doc """
  Kill switch: the `file_times_backfill` service override (default on).
  Off, the runner runs no pass and the ledger stays open.
  """
  @impl true
  def enabled?, do: Engram.ServiceConfig.get(:file_times_backfill, true) == true

  @impl true
  def run_pass, do: run_pass([])

  @doc false
  # Drops the clean-table memory (tests; the ledger closing does it too).
  def forget, do: :persistent_term.erase(@clean)

  @doc false
  # `batch:` overrides the window size, `max_fixed:` the per-walk cap.
  def run_pass(opts) do
    clean = :persistent_term.get(@clean, MapSet.new())

    open =
      for {schema, pairs} <- @tables,
          table = schema.__schema__(:source),
          not MapSet.member?(clean, table),
          {:more, rows} <- [walk(schema, table, pairs, opts)],
          do: {table, rows}

    cond do
      open != [] ->
        :persistent_term.put(@clean, clean_now(open))
        {:more, rows: open |> Enum.map(&elem(&1, 1)) |> Enum.sum()}

      # The last open table closed, but a table skipped this pass walked
      # clean in an earlier one: drift written since would be missed. One
      # confirming pass over all three before done.
      MapSet.size(clean) > 0 ->
        forget()
        {:more, rows: 0}

      true ->
        forget()
        :done
    end
  end

  defp clean_now(open) do
    MapSet.new(for {s, _} <- @tables, do: s.__schema__(:source))
    |> MapSet.difference(MapSet.new(open, &elem(&1, 0)))
  end

  defp walk(schema, table, pairs, opts) do
    tally = %{
      fixed: :counters.new(1, []),
      oor: :counters.new(1, []),
      refresh: :ets.new(:refresh, [:set])
    }

    result =
      try do
        IdWindows.heal_pass("#{name()}:#{table}", schema, &heal(&1, &2, schema, pairs, tally),
          batch_size: Keyword.get(opts, :batch, @batch),
          max_fixed: Keyword.get(opts, :max_fixed, @max_fixed),
          # Three walks share one pass's budget.
          budget_ms: div(IdWindows.pass_budget_ms(), length(@tables))
        )
      after
        report(table, tally)
      end

    case result do
      :done -> :done
      {:more, found} -> {:more, Keyword.get(found, :rows, 0)}
    end
  end

  # One line per table per pass; the payload refresh after every window
  # committed, so the worker sees the NULLed stamps.
  defp report(table, tally) do
    fixed = :counters.get(tally.fixed, 1)
    oor = :counters.get(tally.oor, 1)
    users = tally.refresh |> :ets.tab2list() |> Enum.map(&elem(&1, 0))
    :ets.delete(tally.refresh)

    if fixed > 0,
      do:
        Logger.info(
          "file times repaired",
          Metadata.with_category(:info, :data, table: table, total_count: fixed)
        )

    if oor > 0,
      do:
        Logger.warning(
          "file_time_out_of_range",
          Metadata.with_category(:warning, :data, table: table, total_count: oor)
        )

    if users != [], do: TenantScan.enqueue_users(ReconcileNotePayloads, users)
  end

  # One window: read the rows' doubles and twins by primary key, compute the
  # wanted twins with `FileTime.normalize/1`, write only the drifted rows.
  defp heal(ids, %{repo: repo}, schema, pairs, tally) do
    fields = [:id, :user_id | Enum.flat_map(pairs, &Tuple.to_list/1)]
    # The probe subquery drops the uuid type: ids come back as 16 raw bytes.
    rows =
      from(r in schema, select: map(r, ^fields))
      |> IdWindows.by_id(ids)
      |> repo.all()
      |> Enum.map(&%{&1 | id: Ecto.UUID.cast!(&1.id), user_id: Ecto.UUID.cast!(&1.user_id)})

    drift =
      for row <- rows,
          wanted = Map.new(pairs, fn {d, at} -> {at, FileTime.normalize(row[d])} end),
          not Enum.all?(pairs, fn {_, at} -> FileTime.same_at?(row[at], wanted[at]) end),
          do: {row, wanted}

    written = write(repo, schema, drift)
    done = MapSet.new(written)
    fixed = Enum.filter(drift, fn {row, _} -> MapSet.member?(done, row.id) end)

    :counters.add(tally.fixed, 1, length(written))

    :counters.add(
      tally.oor,
      1,
      Enum.count(fixed, fn {row, _} ->
        Enum.any?(pairs, fn {d, _} -> match?({:error, _}, FileTime.to_at(row[d])) end)
      end)
    )

    refresh_ms_payloads(repo, schema, pairs, fixed, tally)
    {length(written), length(written) < length(drift)}
  end

  defp refresh_ms_payloads(repo, Engram.Notes.Note, pairs, fixed, tally) do
    # Only rows whose served time moved: a v1 floored twin is within
    # `FileTime.twin?/2`, so `epoch/2` already sent the double.
    ms =
      for {row, _} <- fixed,
          Enum.any?(pairs, fn {d, at} ->
            FileTime.ms?(row[d]) and not FileTime.twin?(row[at], row[d])
          end),
          do: row

    if ms != [] do
      ids = Enum.map(ms, & &1.id)

      {_, _} =
        repo.update_all(
          from(n in Engram.Notes.Note,
            where: n.id in ^ids and n.kind == "note" and not is_nil(n.payload_hash)
          ),
          set: [payload_hash: nil]
        )

      :ets.insert(tally.refresh, Enum.map(ms, &{&1.user_id}))
    end

    :ok
  end

  defp refresh_ms_payloads(_repo, _schema, _pairs, _fixed, _tally), do: :ok

  defp write(_repo, _schema, []), do: []

  defp write(repo, schema, drift) do
    rows = Enum.map(drift, &elem(&1, 0))
    ids = Enum.map(rows, & &1.id)
    col = fn key -> Enum.map(rows, & &1[key]) end
    want = fn key -> Enum.map(drift, fn {_, w} -> w[key] end) end

    locked =
      from(r in schema,
        where: r.id in ^ids,
        order_by: r.id,
        lock: "FOR NO KEY UPDATE SKIP LOCKED",
        select: r.id
      )

    {_, written} = repo.update_all(update_query(schema, locked, ids, col, want), [])
    written
  end

  # Compare-and-set on the doubles: a writer that moved one since the read
  # wins, and its row counts as left. Returns the written ids.
  defp update_query(Engram.Notes.Note = schema, locked, ids, col, want) do
    from(r in schema,
      join:
        v in fragment(
          "SELECT * FROM unnest(?::uuid[], ?::float8[], ?::timestamptz[], ?::float8[], ?::timestamptz[]) AS t(id, m, ma, c, ca)",
          type(^ids, {:array, Ecto.UUID}),
          ^col.(:mtime),
          ^want.(:mtime_at),
          ^col.(:ctime),
          ^want.(:ctime_at)
        ),
      on: r.id == field(v, :id),
      where: r.id in subquery(locked),
      where: fragment("? IS NOT DISTINCT FROM ?", r.mtime, field(v, :m)),
      where: fragment("? IS NOT DISTINCT FROM ?", r.ctime, field(v, :c)),
      update: [set: [mtime_at: field(v, :ma), ctime_at: field(v, :ca)]],
      select: r.id
    )
  end

  defp update_query(schema, locked, ids, col, want) do
    from(r in schema,
      join:
        v in fragment(
          "SELECT * FROM unnest(?::uuid[], ?::float8[], ?::timestamptz[]) AS t(id, m, ma)",
          type(^ids, {:array, Ecto.UUID}),
          ^col.(:mtime),
          ^want.(:mtime_at)
        ),
      on: r.id == field(v, :id),
      where: r.id in subquery(locked),
      where: fragment("? IS NOT DISTINCT FROM ?", r.mtime, field(v, :m)),
      update: [set: [mtime_at: field(v, :ma)]],
      select: r.id
    )
  end
end
