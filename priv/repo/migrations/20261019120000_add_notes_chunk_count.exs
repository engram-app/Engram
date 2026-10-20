defmodule Engram.Repo.Migrations.AddNotesChunkCount do
  use Ecto.Migration

  # Expand-only: one nullable column, no backfill, no default.
  #
  # The chunks a full pass over the note's current content would write before
  # the per-note cap, stamped only on a note that holds fewer points than that
  # (floored, or merged under `note_points_cap`); NULL on a plain full index.
  # The index budget sweep promotes from it: what a floor note costs once
  # promoted, and whether a merged note unmerges under a raised cap.
  # `Engram.Indexing` writes it.
  def change do
    alter table(:notes) do
      add :chunk_count, :bigint
    end
  end
end
