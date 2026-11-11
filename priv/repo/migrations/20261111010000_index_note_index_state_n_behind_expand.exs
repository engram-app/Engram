defmodule Engram.Repo.Migrations.IndexNoteIndexStateNBehindExpand do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  A partial index whose predicate IS the `n` backfill's "this note is behind
  the payload version" test, so the fleet walk's per-user probe
  (`Engram.Workers.ReconcileNotePayloads.n_behind_probe/1`) reads a few index
  pages for a done user instead of every one of its notes. Empty in steady
  state (every stamped note at version 6).

  The predicate is the probe's text with literals (Postgres uses a partial
  index only for a query carrying the same text; `drain_test.exs` pins the
  match). ponytail: the `6` is the predicate literal, `PayloadV6.version/0`
  today. The next payload version bump needs a new index; the drain test goes
  red until it ships.

  CONCURRENTLY (the table is written on every index run), so no ACCESS
  EXCLUSIVE lock. Dropped by name first, so a retry after a failed build
  rebuilds an INVALID index. Additive: the previous release ignores it.
  Depends only on `note_index_state.payload_version` (20261030000000) and the
  table (20261026000000), so a release-skipping self-hoster may apply it in
  any batch order after those.
  """

  def up do
    execute "DROP INDEX CONCURRENTLY IF EXISTS note_index_state_n_behind"

    execute """
    CREATE INDEX CONCURRENTLY note_index_state_n_behind ON note_index_state (user_id)
    WHERE points > 0 AND payload_hash IS NOT NULL AND COALESCE(payload_version, 5) < 6
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS note_index_state_n_behind"
  end
end
