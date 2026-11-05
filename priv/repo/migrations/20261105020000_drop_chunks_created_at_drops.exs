defmodule Engram.Repo.Migrations.DropChunksCreatedAtDrops do
  use Ecto.Migration

  # The migration-gates reference check greps lib/ for the bare name, and
  # `created_at` is a live column on notes, users, vaults and others (55
  # hits), so it would fail on references that are not this column. Checked
  # by hand: no lib/ code reads or writes chunks.created_at (Chunk schema has
  # no field; no raw SQL on chunks names it).
  # safety_assured: "created_at is shared by other tables; chunks.created_at has no lib/ reference"

  @moduledoc """
  Contract step for `chunks.created_at`. Nothing reads it, and nothing has
  written it since 20261026000300 (expand, release 0.66.0) made it nullable.
  Every release that could still be running or rolled back to is 0.66.0 or
  later, and none of them write or read the column, so dropping it breaks
  no running task.

  Skip-release safe: a self-hoster jumping from before 0.66.0 applies the
  expand and this drop in one batch, then runs code that never touches the
  column.

  DROP COLUMN is a catalog change (no rewrite) under ACCESS EXCLUSIVE, held
  for milliseconds: fail fast behind a long transaction instead of queueing
  every chunk read, and let the next boot retry.

  `down` restores the column nullable, as the expand left it; old values
  are gone and nothing ever read them.
  """

  def up do
    execute "SET lock_timeout = '5s'"

    alter table(:chunks) do
      remove :created_at
    end

    execute "RESET lock_timeout"
  end

  def down do
    alter table(:chunks) do
      add :created_at, :naive_datetime
    end
  end
end
