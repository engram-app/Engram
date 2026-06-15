defmodule Engram.Repo.Migrations.CreateNotesFts do
  @moduledoc """
  #595 — keyword/full-text search leg. Side table holding a per-note tsvector
  (computed in-app after decrypt, NOT a GENERATED column — a generated column
  can't read `content_ciphertext`). Kept off the hot `notes` row to keep that
  row narrow. Plaintext-derived → same trust class as embeddings; encrypted at
  rest at the storage layer (RDS KMS), RLS-isolated per tenant.
  """
  use Ecto.Migration

  def change do
    create table(:notes_fts, primary_key: false) do
      add :note_id, references(:notes, type: :uuid, on_delete: :delete_all), primary_key: true

      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :vault_id, references(:vaults, type: :uuid, on_delete: :delete_all), null: false
      add :search_vector, :tsvector, null: false

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    # Plain (non-CONCURRENT) GIN is safe here: the table is created in THIS
    # migration so it holds zero rows — nothing to lock. Squawk exempts indexes
    # on same-migration tables. (Steady-state writes ride GIN fastupdate; the
    # bulk backfill worker is where the drop→bulk-load→rebuild dance lives.)
    create index(:notes_fts, [:search_vector], using: :gin)
    create index(:notes_fts, [:vault_id])

    # RLS — identical tenant_isolation shape to notes/chunks. The adapter also
    # scopes by user_id/vault_id explicitly; this is the row-level backstop.
    execute(
      "ALTER TABLE notes_fts ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE notes_fts DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE notes_fts FORCE ROW LEVEL SECURITY",
      "ALTER TABLE notes_fts NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_notes_fts ON notes_fts
        USING ((user_id)::text = (SELECT current_setting('app.current_tenant', true)))
        WITH CHECK ((user_id)::text = (SELECT current_setting('app.current_tenant', true)))
      """,
      "DROP POLICY tenant_isolation_notes_fts ON notes_fts"
    )

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON notes_fts TO engram_app",
      "REVOKE ALL ON notes_fts FROM engram_app"
    )
  end
end
