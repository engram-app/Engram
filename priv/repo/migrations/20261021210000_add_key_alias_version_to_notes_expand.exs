defmodule Engram.Repo.Migrations.AddKeyAliasVersionToNotesExpand do
  use Ecto.Migration

  # squawk-ignore: prefer-bigint-over-int
  #
  # A version stamp of the alias table, bumped by hand when it is
  # regenerated: it never nears 2^31, and 4 more bytes on every note row buy
  # nothing.

  @moduledoc """
  The key alias table (`Engram.Notes.KeyAliases.version/0`) a note's
  frontmatter was last read under, so a regenerated table heals existing
  notes with no operator step (`Engram.DataMigrations.KeyAliases`).

  Not backfilled: NULL means "read before the stamp", which is checked once
  (CPU only; a note whose fields did not move is just stamped). No
  tenant-table DML, so none of the FORCE RLS handling.
  """

  def up do
    alter table(:notes) do
      add :key_alias_version, :integer
    end
  end

  def down do
    alter table(:notes) do
      remove :key_alias_version
    end
  end
end
