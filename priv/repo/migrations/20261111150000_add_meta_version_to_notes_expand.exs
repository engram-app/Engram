defmodule Engram.Repo.Migrations.AddMetaVersionToNotesExpand do
  use Ecto.Migration

  # squawk-ignore: prefer-bigint-over-int
  #
  # A rule version bumped by hand when the title/tags/link derivation
  # changes: it never nears 2^31.

  @moduledoc """
  The derivation rules (`Engram.Notes.Helpers.meta_version/0`) a note's
  stored title, tags and outgoing links were last checked under, so a rule
  change heals existing notes with no operator step
  (`Engram.DataMigrations.NoteMeta`).

  Nullable, no default: metadata-only, no table rewrite. Not backfilled:
  NULL means "never checked", which the migration's walk checks once.
  Unindexed, so the walk's stamp write can stay heap-only and no save path
  pays for it. No tenant-table DML, so none of the FORCE RLS handling.
  """

  def up do
    alter table(:notes) do
      add :meta_version, :integer
    end
  end

  def down do
    alter table(:notes) do
      remove :meta_version
    end
  end
end
