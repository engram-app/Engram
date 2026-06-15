defmodule Mix.Tasks.Engram.IndexAudit do
  @shortdoc "Flag never-scanned and PG18 skip-scan-redundant indexes (read-only)"
  @moduledoc """
  Read-only audit of B-tree indexes that are candidates for removal.

  ## Usage

      mix engram.index_audit

  Connects to the configured Ecto repo, reads `pg_stat_user_indexes` +
  `pg_index` + `pg_stats`, and reports two classes of drop candidate:

    * **never_scanned** — a non-unique, non-primary, valid index whose
      `idx_scan` count is 0. It has never served a query since the last
      statistics reset.
    * **skip_scan_redundant** — a single-column index whose column is the
      immediate second column of a composite index *and* that composite's
      leading column is low-cardinality. PostgreSQL 18 B-tree **skip scans**
      let such a composite serve the single-column lookup on its own, so the
      standalone index is dead weight that only adds write amplification.

  Output includes a copy-paste `DROP INDEX CONCURRENTLY` per candidate. The
  task never drops anything — a human decides.

  ## Caveats — read before dropping

    * `idx_scan` is **cumulative since the last `pg_stat_reset()` / crash**,
      and relative to this node's uptime. A "never scanned" index on a
      freshly-restarted or freshly-created table is a false positive. Confirm
      against a node that has been up across a representative workload.
    * Unique and primary-key indexes are never reported — they enforce
      constraints, not just performance, regardless of scan count.
    * The skip-scan rule is deliberately conservative (immediate-second-column
      only, low-cardinality leading column only) to keep false positives near
      zero. It will miss some genuinely-redundant indexes; that is the safe
      direction.
  """

  use Mix.Task

  # Estimated distinct values at or below which a leading column is "low
  # cardinality" enough for a skip scan to cheaply hop across its values.
  @default_low_cardinality_threshold 100

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    indexes = load_indexes(Engram.Repo)
    indexes |> analyze() |> print()
  end

  @doc """
  Classify a list of index descriptors into drop candidates.

  Each index is a map with keys `:name`, `:table`, `:columns` (ordered list
  of column names), `:scans`, `:unique`, `:primary`, `:valid`,
  `:leading_n_distinct` (estimated distinct values of the first column, or
  `nil` when unknown), and `:size_bytes`.

  Options:

    * `:low_cardinality_threshold` — leading-column distinct ceiling for the
      skip-scan rule. Defaults to `#{@default_low_cardinality_threshold}`.

  Returns `%{never_scanned: [...], skip_scan_redundant: [...]}`.
  """
  def analyze(indexes, opts \\ []) do
    threshold = opts[:low_cardinality_threshold] || @default_low_cardinality_threshold

    %{
      never_scanned: never_scanned(indexes),
      skip_scan_redundant: skip_scan_redundant(indexes, threshold)
    }
  end

  defp never_scanned(indexes) do
    for ix <- indexes, droppable?(ix), ix.scans == 0 do
      %{index: ix.name, table: ix.table, scans: ix.scans, size_bytes: ix.size_bytes}
    end
  end

  defp skip_scan_redundant(indexes, threshold) do
    composites = Enum.filter(indexes, &(&1.valid and length(&1.columns) >= 2))

    for ix <- indexes,
        droppable?(ix),
        [column] <- [ix.columns],
        cover = covering_composite(composites, ix.table, column, threshold),
        cover != nil do
      %{
        index: ix.name,
        table: ix.table,
        column: column,
        covered_by: cover.name,
        leading_n_distinct: cover.leading_n_distinct
      }
    end
  end

  # A composite covers `column` via skip scan when, on the same table, the
  # column sits immediately after a low-cardinality leading column.
  defp covering_composite(composites, table, column, threshold) do
    Enum.find(composites, fn c ->
      c.table == table and
        Enum.at(c.columns, 1) == column and
        low_cardinality?(c.leading_n_distinct, threshold)
    end)
  end

  defp low_cardinality?(n, threshold), do: is_number(n) and n <= threshold

  # Unique / primary indexes enforce constraints — never a drop candidate,
  # whatever their scan count. Invalid indexes are mid-build or failed and
  # are ignored entirely.
  defp droppable?(ix), do: ix.valid and not ix.unique and not ix.primary

  defp load_indexes(repo) do
    %{rows: rows} = repo.query!(index_stats_sql())

    Enum.map(rows, fn [name, table, scans, unique, primary, valid, size, columns, leading] ->
      %{
        name: name,
        table: table,
        scans: scans,
        unique: unique,
        primary: primary,
        valid: valid,
        size_bytes: size,
        columns: Enum.reject(columns || [], &is_nil/1),
        leading_n_distinct: leading && trunc(leading)
      }
    end)
  end

  defp index_stats_sql do
    """
    WITH idx AS (
      SELECT sui.indexrelname AS name,
             sui.relname      AS tbl,
             sui.idx_scan     AS scans,
             ix.indisunique   AS is_unique,
             ix.indisprimary  AS is_primary,
             ix.indisvalid    AS is_valid,
             pg_relation_size(ix.indexrelid) AS size_bytes,
             ix.indrelid,
             ix.indkey
      FROM pg_stat_user_indexes sui
      JOIN pg_index ix ON ix.indexrelid = sui.indexrelid
      WHERE sui.schemaname = 'public'
    ),
    cols AS (
      SELECT idx.name,
             array_agg(a.attname ORDER BY k.ord) AS columns,
             (array_agg(a.attname ORDER BY k.ord))[1] AS leading_col
      FROM idx
      JOIN LATERAL unnest(idx.indkey) WITH ORDINALITY AS k(attnum, ord) ON true
      LEFT JOIN pg_attribute a
        ON a.attrelid = idx.indrelid AND a.attnum = k.attnum
      GROUP BY idx.name
    )
    SELECT idx.name, idx.tbl, idx.scans, idx.is_unique, idx.is_primary,
           idx.is_valid, idx.size_bytes, c.columns,
           CASE
             WHEN s.n_distinct IS NULL THEN NULL
             WHEN s.n_distinct >= 0 THEN s.n_distinct
             ELSE (-s.n_distinct) * GREATEST(pc.reltuples, 0)
           END AS leading_n_distinct
    FROM idx
    JOIN cols c ON c.name = idx.name
    JOIN pg_class pc ON pc.oid = idx.indrelid
    LEFT JOIN pg_stats s
      ON s.schemaname = 'public'
     AND s.tablename = idx.tbl
     AND s.attname = c.leading_col
    ORDER BY idx.tbl, idx.name
    """
  end

  defp print(%{never_scanned: [], skip_scan_redundant: []}) do
    Mix.shell().info("No drop candidates. Every index is scanned or constraint-backed.")
  end

  defp print(result) do
    print_section(
      "NEVER SCANNED (idx_scan = 0 since last stats reset)",
      result.never_scanned,
      fn f -> "  #{f.table}.#{f.index}  (#{format_bytes(f.size_bytes)})" end
    )

    print_section(
      "SKIP-SCAN REDUNDANT (PG18 composite can serve this single-column lookup)",
      result.skip_scan_redundant,
      fn f ->
        "  #{f.table}.#{f.index} on (#{f.column}) — covered by #{f.covered_by} " <>
          "(leading n_distinct ≈ #{f.leading_n_distinct})"
      end
    )

    candidates = Enum.map(result.never_scanned ++ result.skip_scan_redundant, & &1.index)

    if candidates != [] do
      Mix.shell().info("")
      Mix.shell().info("Suggested (review against a long-lived node FIRST):")
      Enum.each(candidates, &Mix.shell().info("  DROP INDEX CONCURRENTLY IF EXISTS #{&1};"))
      Mix.shell().info("")

      Mix.shell().info(
        "idx_scan is cumulative since the last pg_stat_reset() — verify before dropping."
      )
    end
  end

  defp print_section(_title, [], _fmt), do: :ok

  defp print_section(title, findings, fmt) do
    Mix.shell().info("#{title} (#{length(findings)}):")
    Enum.each(findings, &Mix.shell().info(fmt.(&1)))
    Mix.shell().info("")
  end

  defp format_bytes(b) when is_integer(b) and b >= 1_048_576,
    do: "#{Float.round(b / 1_048_576, 1)} MB"

  defp format_bytes(b) when is_integer(b) and b >= 1024, do: "#{Float.round(b / 1024, 1)} KB"
  defp format_bytes(b), do: "#{b} B"
end
