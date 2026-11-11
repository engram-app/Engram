# Shared summary line; see the file for why it is not in lib/.
Code.require_file("migration_log.exs", __DIR__)

defmodule Engram.Repo.Migrations.IndexNameTermsStaleExpand do
  use Ecto.Migration

  alias Engram.Repo.Migrations.MigrationLog

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  `notes_name_terms_stale` / `folders_name_terms_stale`: the live refs whose
  `name_terms` rows were not written for their current name (the stamp is
  neither `'\\x01' || hmac`, written, nor `'\\x00' || hmac`, a name that did not
  decrypt). `Engram.Bookkeeping.Drain` finds their users through them, and
  the `NameTerms` ledger closes when they are empty. Predicates must equal
  `Engram.Search.NameTerms`' text (`drain_test.exs` pins the probes).

  Empty in steady state. Holds every live note and folder between this
  migration and the end of the `NameTerms` backfill.

  Not HOT for the stamp: `name_terms_stamp` is in these predicates, so a
  stamp write is a non-HOT update (an entry in every `notes` / `folders`
  index). It changes only when a ref's name does (create, rename, delete,
  rotation), plus once per live note and folder during the backfill: a
  one-time cost of one row version per ref, paced by the backfill chain.
  Every other predicate column is already indexed, so no other write that
  was heap-only stops being so.

  Additive: the previous release ignores them. Dropped by name first, so a
  retry after a failed CONCURRENTLY build rebuilds an INVALID index.
  """

  def up do
    started = MigrationLog.now()

    execute "DROP INDEX CONCURRENTLY IF EXISTS notes_name_terms_stale"

    execute """
    CREATE INDEX CONCURRENTLY notes_name_terms_stale ON notes (user_id)
    WHERE kind = 'note' AND deleted_at IS NULL AND basename_hmac IS NOT NULL
      AND name_terms_stamp IS DISTINCT FROM ('\\x01'::bytea || basename_hmac)
      AND name_terms_stamp IS DISTINCT FROM ('\\x00'::bytea || basename_hmac)
    """

    execute "DROP INDEX CONCURRENTLY IF EXISTS folders_name_terms_stale"

    execute """
    CREATE INDEX CONCURRENTLY folders_name_terms_stale ON folders (user_id)
    WHERE deleted_at IS NULL
      AND name_terms_stamp IS DISTINCT FROM ('\\x01'::bytea || name_hmac)
      AND name_terms_stamp IS DISTINCT FROM ('\\x00'::bytea || name_hmac)
    """

    # Runs the queued statements, so the line reports the built indexes.
    flush()

    MigrationLog.indexes(
      repo(),
      "index_name_terms_stale",
      ~w(notes_name_terms_stale folders_name_terms_stale),
      started
    )
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS folders_name_terms_stale"
    execute "DROP INDEX CONCURRENTLY IF EXISTS notes_name_terms_stale"
  end
end
