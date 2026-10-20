# priv/repo/migrations/20261020090000_create_embedding_cache_expand.exs
defmodule Engram.Repo.Migrations.CreateEmbeddingCacheExpand do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # Same reason as note_revisions: the table is created empty in this
  # migration, so require-concurrent-index-creation has no rows or writers to
  # block, and lint_migrations.sh has no per-rule per-file exclusion.
  #
  # phase/expand: new table, no backfill. The encrypted per-user vector cache
  # (chunker v5 Task 12, `Engram.Indexing.VectorCache`). Read and written only
  # while `VECTOR_CACHE_ENABLED=true`; with the flag off nothing touches it.
  #
  # One row is one dense vector: `key` is HMAC-SHA256 under the user's
  # content-hash subkey, `vector_ciphertext` is the AES-GCM envelope (format 0,
  # never compressed) of a 32-byte input digest followed by the f16 vector.
  # About 2.3 KB a row with its index entry; see the module doc for the sizing.
  #
  # `note_id` names the note that last wrote the row, so a hard-deleted note
  # takes its rows with it. Rows shared by two notes go with either; it is a
  # cache, the survivor re-embeds once. The user FK cascades the rest.
  #
  # RLS mirrors note_revisions: tenant-scoped on user_id, ENABLE + FORCE,
  # engram_app grants, plus the maintenance_all policy every tenant table needs
  # (Engram.Repo.MaintenanceRoleTest fails without it).
  def change do
    create table(:embedding_cache, primary_key: false) do
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :key, :binary, null: false, primary_key: true
      add :note_id, references(:notes, type: :uuid, on_delete: :delete_all)
      add :vector_ciphertext, :binary, null: false
      add :vector_nonce, :binary, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
      add :last_used_at, :timestamptz, null: false, default: fragment("now()")
    end

    # The notes FK cascade scans it. Partial: a row whose note is gone is
    # already deleted, and NULL is only a row written without one.
    create index(:embedding_cache, [:note_id], where: "note_id IS NOT NULL")

    # A row is ~2.1 KB, past the ~2 KB TOAST threshold, and AES-GCM output never
    # compresses: TOAST would try pglz, fail, then move the value out of line,
    # paying a second heap lookup on every hit. PLAIN keeps it inline.
    execute(
      "ALTER TABLE embedding_cache ALTER COLUMN vector_ciphertext SET STORAGE PLAIN",
      "ALTER TABLE embedding_cache ALTER COLUMN vector_ciphertext SET STORAGE EXTENDED"
    )

    execute(
      "ALTER TABLE embedding_cache ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE embedding_cache DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE embedding_cache FORCE ROW LEVEL SECURITY",
      "ALTER TABLE embedding_cache NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_embedding_cache ON embedding_cache
        USING (user_id::text = (SELECT current_setting('app.current_tenant', true)))
        WITH CHECK (user_id::text = (SELECT current_setting('app.current_tenant', true)))
      """,
      "DROP POLICY IF EXISTS tenant_isolation_embedding_cache ON embedding_cache"
    )

    execute(
      "CREATE POLICY maintenance_all ON embedding_cache TO engram_maintenance USING (true) WITH CHECK (true)",
      "DROP POLICY IF EXISTS maintenance_all ON embedding_cache"
    )

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON embedding_cache TO engram_app",
      "REVOKE ALL ON embedding_cache FROM engram_app"
    )
  end
end
