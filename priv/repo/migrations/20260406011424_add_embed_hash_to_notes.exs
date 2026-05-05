defmodule Engram.Repo.Migrations.AddEmbedHashToNotes do
  use Ecto.Migration

  def change do
    alter table(:notes) do
      add :embed_hash, :text
    end

    # Partial index for reconciliation: quickly find notes needing embedding.
    # Covers NULL embed_hash (never embedded) and stale (content changed since last embed).
    create index(:notes, [:embed_hash],
             name: :idx_notes_embed_pending,
             where: "deleted_at IS NULL AND (embed_hash IS NULL OR embed_hash != content_hash)"
           )
  end
end
