defmodule Engram.Repo.Migrations.CreateMaintenanceCursorsExpand do
  use Ecto.Migration

  @moduledoc """
  Where a bounded maintenance sweep resumes (`Engram.Maintenance.Cursor`): one
  row per sweep, the last key it reached. A per-run cap without a persisted
  cursor rereads the same head of its index every run, so permanent residents
  there (a trashed note in the NULL-head index) starve everything after them,
  and a node-local cursor resets on every deploy or leader change.

  Not tenant data: a cursor holds row ids, never content, and is read only by
  the sweeps, so no RLS. Additive: the previous release ignores it.
  """

  def change do
    create table(:maintenance_cursors, primary_key: false) do
      add :name, :text, primary_key: true
      add :cursor, :map, null: false
      add :updated_at, :timestamptz, null: false, default: fragment("now()")
    end

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON maintenance_cursors TO engram_app",
      "REVOKE ALL ON maintenance_cursors FROM engram_app"
    )

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON maintenance_cursors TO engram_maintenance",
      "REVOKE ALL ON maintenance_cursors FROM engram_maintenance"
    )
  end
end
