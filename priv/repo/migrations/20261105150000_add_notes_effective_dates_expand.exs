defmodule Engram.Repo.Migrations.AddNotesEffectiveDatesExpand do
  use Ecto.Migration

  @moduledoc """
  The note filter's date columns, all derived in Elixir by every content
  save (`Note.changeset/2`, `Engram.Notes.EffectiveDates`):

    * `fm_updated` / `fm_created_s`: the v5 frontmatter `updated` / `created`
      dates in unix seconds (`FlatFields.dates/1`, the payload's parser;
      `fm_timestamp` / `fm_created` keep OKF's).
    * `eff_updated` / `eff_created`: the frontmatter date, else the file time
      (`Engram.FileTime`), else NULL (the index expression then uses the
      row time). Indexed by the next migration.
    * `eff_v`: the `version` they were derived at.
      `Engram.DataMigrations.EffectiveDates` recomputes rows where they differ.

  Nullable, no default: a catalog-only change. Earlier heads of this PR used
  versions 20261105100000-100200 and 20261105130000-130200; these are newer
  than the file-time expand (20261105140000), whose FileTime the stored
  dates are derived with, so a database migrated at an earlier head applies
  them and the migration gates see them.
  """

  @cols ~w(fm_updated fm_created_s eff_updated eff_created eff_v)

  def up do
    execute "SET lock_timeout = '5s'"
    for c <- @cols, do: execute("ALTER TABLE notes ADD COLUMN IF NOT EXISTS #{c} bigint")
    execute "RESET lock_timeout"
  end

  def down do
    for c <- Enum.reverse(@cols), do: execute("ALTER TABLE notes DROP COLUMN IF EXISTS #{c}")
  end
end
