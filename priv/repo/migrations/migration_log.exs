defmodule Engram.Repo.Migrations.MigrationLog do
  @moduledoc """
  One summary line per migration: counts and elapsed ms, never an id or a
  row value. `:boot` info lines ship to Loki (`category: :boot`,
  `loki_ship: true` spelled out, as 20261110130000 does: a migration calls
  no app module, the N-1 gate runs it on the previous release).

  Shared by migrations through `Code.require_file("migration_log.exs",
  __DIR__)`, not `lib/`, for the reason given in lock_timeout_retry.exs.
  Applied migrations depend on it, so treat it as frozen: change behaviour
  in a new file.
  """

  require Logger

  @doc "The clock `done/3` measures from (monotonic ms)."
  def now, do: System.monotonic_time(:millisecond)

  @doc "Logs `migration`'s `counts` (a keyword list of integers or short strings)."
  def done(migration, counts, started) do
    body = Enum.map_join(counts, ", ", fn {k, v} -> "#{k} #{v}" end)

    Logger.info("migration #{migration}: #{body} (#{now() - started} ms)",
      category: :boot,
      loki_ship: true
    )
  end

  @doc "Logs how many of `indexes` are valid and their estimated entries (`reltuples`)."
  def indexes(repo, migration, indexes, started) do
    %{rows: [[valid, entries]]} =
      repo.query!(
        """
        SELECT count(*) FILTER (WHERE i.indisvalid),
               COALESCE(sum(GREATEST(c.reltuples, 0)), 0)::bigint
        FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid
        WHERE c.relname = ANY($1)
        """,
        [indexes],
        []
      )

    done(migration, [indexes_valid: "#{valid}/#{length(indexes)}", entries_est: entries], started)
  end

  @doc "How many of `columns` (`{table, column}`) exist."
  def columns(repo, columns) do
    Enum.count(columns, fn {table, column} ->
      repo.query!(
        "SELECT 1 FROM information_schema.columns WHERE table_name = $1 AND column_name = $2",
        [table, column],
        []
      ).num_rows == 1
    end)
  end
end
