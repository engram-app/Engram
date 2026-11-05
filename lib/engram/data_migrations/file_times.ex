defmodule Engram.DataMigrations.FileTimes do
  @moduledoc """
  R25 migrate-data: fills the `*_at` timestamptz twins (migration
  20261105140000) from the epoch doubles: `notes.mtime_at` / `ctime_at`,
  `attachments.mtime_at`, `attachment_uploads.mtime_at`.

  A row is work when its `*_at` IS DISTINCT FROM `Engram.FileTime.to_at/1`
  of its double, NULL or not: a release before the expand phase, running
  during a rollout or after a rollback, moves a double without its twin and
  leaves a stale non-NULL value. Values are computed here with `FileTime`
  (never `to_timestamp`, which rounds), so the backfill and every writer
  share one normalizer. A legacy out-of-range double is NULL, counted and
  logged (`file_time_out_of_range`), never an aborted window.

  Each table is its own `IdWindows.heal_pass/4` walk (cursor
  `file_times:<table>`); the ledger is done when all three walks are clean.
  Each window reads only the id, doubles and twins of its rows by primary
  key, then writes only the drifted rows, `FOR UPDATE SKIP LOCKED` and a
  compare-and-set on the double, so a concurrent writer wins and its row
  counts as left (rewalked). The `file times repaired` count is the guard
  against a writer that skips the twin: after the first full walk it should
  stay 0. Only `*_at` columns are written: no trigger fires (every `notes`
  trigger is `UPDATE OF` other columns), `updated_at`/`seq` never move, no
  sync fan-out. Not re-verified: every writer of this and the previous
  release sets the twin.
  """
  @behaviour Engram.DataMigration

  import Ecto.Query

  alias Engram.Backfill.IdWindows
  alias Engram.FileTime
  alias Engram.Logger.Metadata

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

  @impl true
  def name, do: "file_times"

  @impl true
  def version, do: 1

  @impl true
  def run_pass, do: run_pass([])

  @doc false
  # `batch:` overrides the window size (tests walk a few rows).
  def run_pass(opts) do
    results =
      for {schema, pairs} <- @tables do
        table = schema.__schema__(:source)

        result =
          IdWindows.heal_pass("#{name()}:#{table}", schema, &heal(&1, &2, schema, pairs),
            batch_size: Keyword.get(opts, :batch, @batch),
            max_fixed: Keyword.get(opts, :max_fixed, @max_fixed),
            # Three walks share one pass's budget.
            budget_ms: div(IdWindows.pass_budget_ms(), length(@tables))
          )

        {table, result}
      end

    open = for {table, {:more, found}} <- results, do: {table, Keyword.get(found, :rows, 0)}

    # The missed-writer guard: after the first full walk this stays silent.
    for {table, n} <- open, n > 0 do
      Logger.info(
        "file times repaired",
        Metadata.with_category(:info, :data, table: table, count: n)
      )
    end

    if open == [], do: :done, else: {:more, rows: open |> Enum.map(&elem(&1, 1)) |> Enum.sum()}
  end

  # One window: read the rows' doubles and twins by primary key, compute the
  # wanted twins in Elixir, write only the drifted rows.
  defp heal(ids, %{repo: repo}, schema, pairs) do
    fields = [:id | Enum.flat_map(pairs, &Tuple.to_list/1)]
    rows = repo.all(IdWindows.by_id(from(r in schema, select: map(r, ^fields)), ids))

    {drift, out_of_range} =
      Enum.reduce(rows, {[], 0}, fn row, {drift, oor} ->
        {wanted, bad} = wanted(row, pairs)
        clean? = Enum.all?(pairs, fn {_, at} -> same?(row[at], wanted[at]) end)
        drift = if clean?, do: drift, else: [{row, wanted} | drift]
        {drift, oor + bad}
      end)

    if out_of_range > 0 do
      Logger.warning(
        "file_time_out_of_range",
        Metadata.with_category(:warning, :data,
          table: schema.__schema__(:source),
          count: out_of_range
        )
      )
    end

    fixed = write(repo, schema, pairs, drift)
    {fixed, fixed < length(drift)}
  end

  defp wanted(row, pairs) do
    Enum.reduce(pairs, {%{}, 0}, fn {double, at}, {acc, bad} ->
      case FileTime.to_at(row[double]) do
        {:ok, v} -> {Map.put(acc, at, v), bad}
        {:error, :out_of_range} -> {Map.put(acc, at, nil), bad + 1}
      end
    end)
  end

  defp same?(nil, nil), do: true
  defp same?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :eq
  defp same?(_, _), do: false

  defp write(_repo, _schema, _pairs, []), do: 0

  defp write(repo, schema, pairs, drift) do
    rows = Enum.map(drift, &elem(&1, 0))
    ids = Enum.map(rows, & &1.id)
    col = fn key -> Enum.map(rows, & &1[key]) end
    want = fn key -> Enum.map(drift, fn {_, w} -> w[key] end) end

    locked =
      from(r in schema,
        where: r.id in ^ids,
        order_by: r.id,
        lock: "FOR UPDATE SKIP LOCKED",
        select: r.id
      )

    {n, _} = repo.update_all(update_query(schema, pairs, locked, ids, col, want), [])
    n
  end

  # Compare-and-set on the doubles: a writer that moved one since the read
  # wins, and its row counts as left.
  defp update_query(schema, [mtime: :mtime_at, ctime: :ctime_at], locked, ids, col, want) do
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
      update: [set: [mtime_at: field(v, :ma), ctime_at: field(v, :ca)]]
    )
  end

  defp update_query(schema, [mtime: :mtime_at], locked, ids, col, want) do
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
      update: [set: [mtime_at: field(v, :ma)]]
    )
  end
end
