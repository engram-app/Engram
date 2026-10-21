defmodule Engram.Repo.Migrations.AddNotesIndexTier do
  use Ecto.Migration

  # Expand-only: one nullable column, no backfill, no default.
  #
  # How much of the Free index budget a note holds. NULL is a full index
  # (one point per chunk, dense where the embed budget allows). "floor" is a
  # single sparse-only point for the whole note, for a note that never had
  # dense vectors; "floor_paid" is the same, for a note whose dense vectors
  # were dropped on demotion, so promoting it back is never charged twice.
  # `Engram.Indexing` reads and writes it.
  def change do
    alter table(:notes) do
      add :index_tier, :text
    end
  end
end
