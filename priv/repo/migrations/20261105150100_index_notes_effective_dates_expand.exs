defmodule Engram.Repo.Migrations.IndexNotesEffectiveDatesExpand do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  `notes_eff_updated_live` / `notes_eff_created_live`: a date-range filter
  (`Engram.Search.NoteFilter`) as one index range over a vault's live notes,
  on the effective date (frontmatter, else file time, else row time).
  INCLUDE `(id, user_id)` and the expression's columns so the range and its
  complement are index-only (`user_id` because the RLS policy reads it).

  The expression is `COALESCE(stored effective date, row time)`
  (`Engram.Notes.EffectiveDates.index_sql/1`): the stored part is computed
  in Elixir by the content save, so no date is parsed and no client number
  is cast in SQL. It is written out here because a migration must not
  change with the code: Postgres uses an expression index only for an
  identical expression, and
  `effective_dates_parity_test.exs` fails if these and `index_sql/1` drift.

  Staging EXPLAIN 2026-11-05 (1,518-note vault): without them a date range
  read the heap of every live note, 7 to 13 ms per 1k notes.

  Write cost: their columns change only on a content save, which is already
  non-HOT (`notes_recent_index` holds `updated_at`), so each save adds one
  entry per index and no HOT update is lost. The ctime batch fill touches
  `eff_created` only on rows with no created date yet (once per note).

  Additive: the previous release ignores them. Dropped by name first, so a
  retry after a failed CONCURRENTLY build rebuilds an INVALID index.
  """

  @live "deleted_at IS NULL AND kind = 'note'"

  @exprs %{
    "notes_eff_updated_live" => "COALESCE(eff_updated, engram_epoch_s(updated_at))",
    "notes_eff_created_live" => "COALESCE(eff_created, engram_epoch_s(created_at))"
  }

  # `id, user_id` for the answer and the RLS policy, plus the expression's
  # own columns: Postgres plans an index-only scan only when every column
  # the query names is in the index, the ones inside an indexed expression
  # included.
  @include %{
    "notes_eff_updated_live" => ~w(id user_id eff_updated updated_at),
    "notes_eff_created_live" => ~w(id user_id eff_created created_at)
  }

  # Whole unix seconds of a row time, for both column types: notes'
  # `updated_at` / `created_at` are `timestamp` today and move to
  # `timestamptz` (`Engram.Repo.Utc`). An index expression must be IMMUTABLE;
  # both bodies are zone-independent (the interval since a `timestamp` 1970,
  # and the epoch of a `timestamptz`, which is the same instant in any zone),
  # so declaring them IMMUTABLE is sound. ALTER COLUMN TYPE rebuilds the
  # indexes from their text, which then resolves the timestamptz overload.
  # `floor`, not a bare cast: the numeric cast rounds, `DateTime.to_unix/1`
  # truncates.
  @epoch_fns [
    {"timestamp", "floor(extract(epoch FROM $1 - timestamp '1970-01-01'))::bigint"},
    {"timestamptz", "floor(extract(epoch FROM $1))::bigint"}
  ]

  def up do
    for {type, body} <- @epoch_fns do
      execute """
      CREATE OR REPLACE FUNCTION engram_epoch_s(#{type}) RETURNS bigint
      LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $fn$ SELECT #{body} $fn$
      """
    end

    for {name, expr} <- @exprs do
      execute "DROP INDEX CONCURRENTLY IF EXISTS #{name}"

      execute """
      CREATE INDEX CONCURRENTLY #{name} ON notes (vault_id, (#{expr}))
      INCLUDE (#{Enum.join(@include[name], ", ")}) WHERE #{@live}
      """
    end
  end

  def down do
    for name <- Map.keys(@exprs) do
      execute "DROP INDEX CONCURRENTLY IF EXISTS #{name}"
    end

    for {type, _} <- @epoch_fns, do: execute("DROP FUNCTION IF EXISTS engram_epoch_s(#{type})")
  end
end
