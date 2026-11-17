defmodule Engram.Repo.Migrations.DropFileTimeDoublesDrops do
  use Ecto.Migration

  # The migration-gates reference check greps lib/ for the bare names, and
  # `mtime` / `ctime` stay in lib/ as the client's wire fields and the
  # schemas' virtual (cast-only) fields. Checked by hand: since R25 step (b)
  # no lib/ code reads or writes the columns (no non-virtual schema field,
  # no raw SQL naming them; `Engram.FileTimeDoublesGoneTest` pins it).
  # safety_assured: "mtime/ctime stay in lib/ as wire params and virtual fields; no column reference since R25 step (b)"

  @moduledoc """
  R25 contract step (c): drops the epoch doubles `notes.mtime`,
  `notes.ctime`, `attachments.mtime` and `attachment_uploads.mtime`. The
  `*_at` timestamptz columns hold the file times.

  Ships in the release after step (b) (which stopped reading and writing
  them, and whose boot migration 20261117120000 filled every NULL twin from
  its double), so no release that can still run or be rolled back to
  touches the columns. Skip-release safe: a self-hoster jumping from before
  step (b) applies 20261117120000 (the fill) before this one in the same
  batch.

  DROP COLUMN is a catalog change (no rewrite, no index on these columns)
  under ACCESS EXCLUSIVE, held for milliseconds per table. A 5 s
  `lock_timeout`: behind a long transaction it fails fast instead of
  queueing every note read, and the next boot retries (rerun-safe, IF
  EXISTS). The heap space is reclaimed as rows are rewritten, not at drop.

  `down` restores the columns nullable and empty; the twins keep the times.
  """

  def up do
    execute "SET lock_timeout = '5s'"

    alter table(:notes) do
      remove_if_exists :mtime, :float
      remove_if_exists :ctime, :float
    end

    alter table(:attachments), do: remove_if_exists(:mtime, :float)
    alter table(:attachment_uploads), do: remove_if_exists(:mtime, :float)

    execute "RESET lock_timeout"
  end

  def down do
    alter table(:notes) do
      add_if_not_exists :mtime, :float
      add_if_not_exists :ctime, :float
    end

    alter table(:attachments), do: add_if_not_exists(:mtime, :float)
    alter table(:attachment_uploads), do: add_if_not_exists(:mtime, :float)
  end
end
