defmodule Engram.Repo.Migrations.DropNotesFileTimeDoublesDrops do
  use Ecto.Migration

  # The migration-gates reference check greps lib/ for the bare names, and
  # `mtime` / `ctime` stay in lib/ as the client's wire params and the
  # schemas' virtual (cast-only) fields. No lib/ code reads or writes the
  # columns since R25 step (b): `Engram.FileTimeDoublesGoneTest` checks the
  # catalog, that the schemas map them only as virtual fields, and that no
  # lib/ SQL string or query binding names them.
  # safety_assured: "mtime/ctime stay in lib/ as wire params and virtual fields; no column reference since R25 step (b)"

  @moduledoc """
  R25 contract step (c): drops `notes.mtime` / `notes.ctime`. The `*_at` timestamptz holds the
  file time. This is the last of the three (20261117170000 to 20261117170200), so the
  notes lock is taken alone and last.

  Ships in the release after step (b), which stopped reading and writing
  the doubles and whose boot migration 20261117160000 filled every NULL
  twin from them, so no release that can run or be rolled back to touches
  the column. Skip-release safe: a jump from before (b) applies that fill
  first, in the same batch.

  DROP COLUMN is a catalog change (no rewrite; no index, trigger or view
  names the column) under ACCESS EXCLUSIVE, held for milliseconds. A 5 s
  `lock_timeout` (SET LOCAL, this migration's transaction only): behind a
  long transaction it fails fast instead of queueing every read, and the
  next boot retries (IF EXISTS, rerun-safe). `down` restores it nullable
  and empty.
  """

  def up do
    execute "SET LOCAL lock_timeout = '5s'"

    alter table(:notes) do
      remove_if_exists :mtime, :float
      remove_if_exists :ctime, :float
    end
  end

  def down do
    alter table(:notes) do
      add_if_not_exists :mtime, :float
      add_if_not_exists :ctime, :float
    end
  end
end
