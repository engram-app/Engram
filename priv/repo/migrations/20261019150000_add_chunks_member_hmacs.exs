defmodule Engram.Repo.Migrations.AddChunksMemberHmacs do
  use Ecto.Migration

  # Expand-only: one nullable column, no backfill, no default.
  #
  # On a merged row (several chunks in one point, under `note_points_cap`):
  # the leading 16 hex chars of each member chunk's own reuse fingerprint.
  # NULL on every other row. A pass meters a regrouped point by its members
  # that changed, and a note with any such row is merged (hysteresis).
  # `Engram.Indexing` writes it.
  def change do
    alter table(:chunks) do
      add :member_hmacs, {:array, :string}
    end
  end
end
