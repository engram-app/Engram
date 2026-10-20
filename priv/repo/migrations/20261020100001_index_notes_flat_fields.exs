defmodule Engram.Repo.Migrations.IndexNotesFlatFields do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Filter lookups on the v5 flat fields (follow-up Engram#2083 reads them).
  # Partial on NOT NULL: most notes set none of these keys, so each index
  # holds only the notes that do.
  @exact ~w(status_hmac author_hmac rev_by_hmac proj_hmac)a
  @ranges ~w(fm_updated fm_reviewed fm_expires fm_due fm_priority)a

  def change do
    for col <- @exact ++ @ranges do
      create index(:notes, [:user_id, col], where: "#{col} IS NOT NULL", concurrently: true)
    end

    create index(:notes, [:src_hmac],
             using: :gin,
             where: "src_hmac IS NOT NULL",
             concurrently: true
           )
  end
end
