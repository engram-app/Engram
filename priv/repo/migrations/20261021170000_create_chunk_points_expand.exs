defmodule Engram.Repo.Migrations.CreateChunkPointsExpand do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # Created empty in this same migration, so require-concurrent-index-creation
  # is moot (no rows, no writers to block); same reasoning as note_attrs.
  #
  # phase/expand: a new table, no backfill (the v5 indexing pass fills it).
  #
  # The lean per-point chunk table (notes-chunks-hyperopt 2.4/2.4b): one row
  # per Qdrant point, keyed by the point id, carrying what search shows for a
  # hit. Written next to `chunks` (same transaction) behind
  # `:chunk_text_write`; `chunks` and its readers stay until PR-18.
  #
  # Columns are ordered for alignment (16-byte uuids, then int4s, then the
  # int2, then the varlenas). No vault_id (search takes it from the note) and
  # no context_hmac (a v5 point id already binds note, fingerprint and
  # ordinal). user_id is the RLS column only: no FK, no index; a user delete
  # reaches these rows through note_id (notes cascade from users).
  #
  #   * slice_sum: keyed checksum of the chunk's display text (first 4
  #     bytes of HMAC-SHA256 under the user's content-hash subkey). Search re-derives a
  #     small note's chunk from its content and checks it.
  #   * member_fps: a merged point's member fingerprints, 8-byte prefixes
  #     concatenated.
  #   * display_ct: the text and heading in ONE envelope, only for notes whose
  #     plaintext is at least 32 KB at index time. STORAGE EXTERNAL: stored
  #     out of line uncompressed, as it is already zstd inside the envelope.
  def change do
    create table(:chunk_points, primary_key: false, options: "WITH (fillfactor = 100)") do
      add :point_id, :uuid, primary_key: true
      add :note_id, references(:notes, type: :uuid, on_delete: :delete_all), null: false
      add :user_id, :uuid, null: false
      add :char_start, :integer
      add :char_end, :integer
      add :token_count, :integer
      add :slice_sum, :integer
      add :position, :smallint
      add :member_fps, :binary
      add :display_ct, :binary
    end

    create unique_index(:chunk_points, [:note_id, :position])

    # DEK rotation visits only rows holding an envelope (`TenantSweep`).
    create index(:chunk_points, [:user_id, :point_id],
             name: :chunk_points_with_display_index,
             where: "display_ct IS NOT NULL"
           )

    execute(
      "ALTER TABLE chunk_points ALTER COLUMN display_ct SET STORAGE EXTERNAL",
      "ALTER TABLE chunk_points ALTER COLUMN display_ct SET STORAGE EXTENDED"
    )

    execute(
      "ALTER TABLE chunk_points ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE chunk_points DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE chunk_points FORCE ROW LEVEL SECURITY",
      "ALTER TABLE chunk_points NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_chunk_points ON chunk_points
        USING (user_id = (SELECT NULLIF((SELECT current_setting('app.current_tenant', true)), '')::uuid))
        WITH CHECK (user_id = (SELECT NULLIF((SELECT current_setting('app.current_tenant', true)), '')::uuid))
      """,
      "DROP POLICY IF EXISTS tenant_isolation_chunk_points ON chunk_points"
    )

    execute(
      "CREATE POLICY maintenance_all ON chunk_points TO engram_maintenance USING (true) WITH CHECK (true)",
      "DROP POLICY IF EXISTS maintenance_all ON chunk_points"
    )

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON chunk_points TO engram_app",
      "REVOKE ALL ON chunk_points FROM engram_app"
    )
  end
end
