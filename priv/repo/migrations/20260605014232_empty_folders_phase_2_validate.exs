defmodule Engram.Repo.Migrations.EmptyFoldersPhase2Validate do
  use Ecto.Migration

  # Phase 2: validate the per-kind CHECK constraint added in phase 1.
  # VALIDATE CONSTRAINT scans the table once under SHARE UPDATE EXCLUSIVE,
  # which does not block reads or writes. Runs in a transaction.

  def up do
    execute "ALTER TABLE notes VALIDATE CONSTRAINT notes_kind_shape_check"
  end

  def down do
    # No-op: VALIDATE is not reversible. The constraint stays NOT VALID
    # only in the sense that phase 1's down would drop it entirely.
    :ok
  end
end
