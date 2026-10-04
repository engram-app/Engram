defmodule Engram.Repo.Migrations.AddEmbedCrashStampToNotesExpand do
  @moduledoc """
  Dead-man stamp for EmbedNote's crash-loop guard (prod worker OOM, 2026-10-03).

  EmbedNote writes `embed_started_at` / `embed_started_by` / `embed_started_hash`
  before it embeds and clears them when the attempt returns. A stamp still
  present when the next attempt starts, from a node that is gone, is one hard
  death charged to exactly this note. `embed_crashes` counts those deaths for
  the content in `embed_started_hash`, so an edit resets it.

  Nullable adds only: metadata-only on PG11+, no rewrite, no default.
  :text, :timestamptz and :bigint for Squawk (prefer-text, prefer-timestamp-tz,
  prefer-bigint); the schema fields stay :string, :utc_datetime_usec, :integer.
  """
  use Ecto.Migration

  def change do
    alter table(:notes) do
      add :embed_started_at, :timestamptz
      add :embed_started_by, :text
      add :embed_started_hash, :text
      add :embed_crashes, :bigint
    end
  end
end
