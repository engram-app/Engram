# Shared helper; see the file for why it is not in lib/.
Code.require_file("lock_timeout_retry.exs", __DIR__)

defmodule Engram.Repo.Migrations.DropNotesFileTimeDoublesDrops do
  use Ecto.Migration

  alias Engram.Repo.Migrations.LockTimeoutRetry

  @disable_ddl_transaction true
  @disable_migration_lock true

  # The migration-gates reference check greps lib/ for the bare names, and
  # `mtime` / `ctime` stay in lib/ as the client's wire params and the
  # schemas' virtual (cast-only) fields. No lib/ code reads or writes the
  # columns since R25 step (b): `Engram.FileTimeDoublesGoneTest` checks the
  # catalog, that the schemas map them only as virtual fields, and that no
  # lib/ SQL string or query binding names them.
  # safety_assured: "mtime/ctime stay in lib/ as wire params and virtual fields; no column reference since R25 step (b)"

  @moduledoc """
  R25 contract step (c): drops `notes.mtime` / `notes.ctime`. The `*_at` timestamptz holds the
  file time. This is the last of the three (20261119100000 to 20261119100200), so the
  notes lock is taken alone and last.

  Ships in the release after step (b), which stopped reading and writing
  the doubles and whose boot migration 20261118100100 filled every NULL
  twin from them, so no release that can run or be rolled back to touches
  the column. Skip-release safe on a single-node install: a jump from
  before (b) applies that fill first, in the same batch. A multi-node
  install must not run a pre-(b) node beside this release (it would read
  the dropped column).

  DROP COLUMN is a catalog change (no rewrite; no index, trigger or view
  names the column) under ACCESS EXCLUSIVE, held for milliseconds, in its
  own autocommit statement. It runs through `LockTimeoutRetry` (as
  20261114120000): a 5 s `lock_timeout`, retried twice, so behind a long
  transaction it fails fast instead of queueing every read, and only then
  raises (the next boot retries; IF EXISTS, rerun-safe). `down` restores it
  nullable and empty.
  """

  def up do
    LockTimeoutRetry.with_lock_timeout(repo(), [
      # One statement: the notes lock is taken once.
      "ALTER TABLE notes DROP COLUMN IF EXISTS mtime, DROP COLUMN IF EXISTS ctime"
    ])
  end

  def down do
    LockTimeoutRetry.with_lock_timeout(repo(), [
      "ALTER TABLE notes ADD COLUMN IF NOT EXISTS mtime double precision, " <>
        "ADD COLUMN IF NOT EXISTS ctime double precision"
    ])
  end
end
