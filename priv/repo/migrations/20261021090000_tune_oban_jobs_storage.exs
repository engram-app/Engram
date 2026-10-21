defmodule Engram.Repo.Migrations.TuneObanJobsStorage do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # oban_jobs is a queue: every row is inserted, updated a few times, then
  # deleted by the Pruner. The default autovacuum trigger (20% of the table
  # dead) lets the dead tuples pile up between runs, and every one of them is
  # read by the PromEx queue-count poll. fillfactor 85 leaves room on the page
  # so state transitions can be HOT updates.
  #
  # Both are storage parameters, which take SHARE UPDATE EXCLUSIVE: they do not
  # block reads or writes.
  #
  # oban_jobs_meta_index (GIN on meta) had 1 scan in prod since June. Nothing in
  # lib/ or in Oban 2.24's queries filters on meta (Oban only writes it, via
  # jsonb_set on snooze), so it is pure write cost on every insert.
  def up do
    execute "ALTER TABLE oban_jobs SET (autovacuum_vacuum_scale_factor = 0.02, fillfactor = 85)"
    drop_if_exists index(:oban_jobs, [:meta], name: :oban_jobs_meta_index, concurrently: true)
  end

  def down do
    create_if_not_exists index(:oban_jobs, [:meta],
                           name: :oban_jobs_meta_index,
                           using: :gin,
                           concurrently: true
                         )

    execute "ALTER TABLE oban_jobs RESET (autovacuum_vacuum_scale_factor, fillfactor)"
  end
end
