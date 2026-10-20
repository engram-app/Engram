defmodule Engram.Repo.Migrations.IndexNotesReconcileDue do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # The 5-minute ReconcileEmbeddings sweep (`reconcile_embeddings.ex`, the
  # `eligible` query) filters on exactly this predicate and orders by
  # updated_at with a LIMIT. `idx_notes_embed_pending` has no arm for
  # `dense_indexed_hash IS NULL`, so the planner could not use it and seq-scanned
  # every note on every tick. The predicate text must stay the query's: Postgres
  # uses a partial index only when the query's WHERE implies it.
  # ReconcileEmbeddingsIndexPlanTest pins the plan.
  #
  # idx_notes_embed_pending is dropped: this index's predicate is a superset of
  # its, and nothing else filters on it.
  def up do
    # A CONCURRENTLY build that fails (lock timeout, deploy kill) leaves an
    # INVALID index under its name, which a retry would skip or trip on.
    # Dropping the name first makes the retry rebuild it.
    drop_if_exists index(:notes, [], name: :notes_reconcile_due, concurrently: true)

    create index(:notes, [:updated_at],
             name: :notes_reconcile_due,
             where:
               "kind = 'note' AND deleted_at IS NULL AND " <>
                 "(embed_hash IS NULL OR embed_hash <> content_hash OR dense_indexed_hash IS NULL)",
             concurrently: true
           )

    drop_if_exists index(:notes, [:embed_hash],
                     name: :idx_notes_embed_pending,
                     concurrently: true
                   )
  end

  def down do
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_notes_embed_pending
      ON notes (embed_hash)
      WHERE deleted_at IS NULL AND kind = 'note'
        AND (embed_hash IS NULL OR embed_hash <> content_hash)
    """

    drop_if_exists index(:notes, [:updated_at], name: :notes_reconcile_due, concurrently: true)
  end
end
