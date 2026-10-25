defmodule Engram.Repo.Migrations.ChunksCreatedAtNullableExpand do
  use Ecto.Migration

  # squawk-ignore: ban-drop-not-null
  # Nothing reads the column (no client to break); this is the expand step.

  # `chunks.created_at` has no reader. This release stops writing it; the
  # previous release still does, which a nullable column accepts, so a
  # rolling deploy and a rollback both keep working. The contract release
  # drops the column.
  #
  # DROP NOT NULL is a catalog change (no scan, no rewrite) under ACCESS
  # EXCLUSIVE, held for milliseconds: fail fast rather than queue every
  # chunk read behind a long transaction.
  def up do
    execute "SET lock_timeout = '5s'"
    execute "ALTER TABLE chunks ALTER COLUMN created_at DROP NOT NULL"
    execute "RESET lock_timeout"
  end

  # Rows written by this release carry NULL: backfill before restoring it.
  # Unforced for the UPDATE (FORCE RLS would filter it to zero rows), and
  # SET NOT NULL fails loud if any row was missed.
  def down do
    execute "ALTER TABLE chunks NO FORCE ROW LEVEL SECURITY"
    execute "UPDATE chunks SET created_at = now() WHERE created_at IS NULL"
    execute "ALTER TABLE chunks ALTER COLUMN created_at SET NOT NULL"
    execute "ALTER TABLE chunks FORCE ROW LEVEL SECURITY"
  end
end
