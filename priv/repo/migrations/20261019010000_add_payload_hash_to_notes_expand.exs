defmodule Engram.Repo.Migrations.AddPayloadHashToNotesExpand do
  use Ecto.Migration

  @moduledoc """
  Hash of the note-level Qdrant payload last written to a note's points, so a
  re-index skips the `set_payload` on reused points when nothing note-level
  moved. On Qdrant 1.18 every `set_payload` copies its points into a new
  segment, so refreshing unconditionally rewrote the collection on each pass.

  Expand-only, not backfilled: NULL means "unknown", which refreshes once and
  stamps. No tenant-table DML, so none of the FORCE RLS handling.
  """

  def up do
    alter table(:notes) do
      add :payload_hash, :binary
    end
  end

  def down do
    alter table(:notes) do
      remove :payload_hash
    end
  end
end
