defmodule Engram.Repo.Migrations.NoteIndexStatePayloadVersionExpand do
  use Ecto.Migration

  @moduledoc """
  `note_index_state.payload_version`: the payload shape a note's Qdrant points
  were last written with, so a payload-only change (a key's value or shape, no
  new vectors) can reach every existing note without an embedder call or an
  operator step. `ReconcileNotePayloads` selects a note whose stamp is behind
  the code's `@payload_version`.

  NULL is "never stamped" and counts as the version before the stamp existed
  (the reader treats it as the current baseline), so nothing is backfilled and
  nothing is selected until a release bumps the constant. The column is not
  mirrored from `notes`: only the payload writers set it. Nullable, no
  default: a metadata-only change. The previous release never reads it.
  """

  def up do
    execute "SET lock_timeout = '5s'"
    # A version number, a handful of values ever: smallint on purpose.
    execute "-- squawk-ignore prefer-bigint-over-smallint\n" <>
              "ALTER TABLE note_index_state ADD COLUMN IF NOT EXISTS payload_version smallint"

    execute "RESET lock_timeout"
  end

  def down do
    execute "SET lock_timeout = '5s'"
    execute "ALTER TABLE note_index_state DROP COLUMN IF EXISTS payload_version"
    execute "RESET lock_timeout"
  end
end
