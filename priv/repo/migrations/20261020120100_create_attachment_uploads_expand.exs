defmodule Engram.Repo.Migrations.CreateAttachmentUploadsExpand do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # Same two squawk rules as note_revisions, both moot for a table created
  # empty in this migration: require-concurrent-index-creation (no rows, no
  # writers) and prefer-bigint-over-int (part_size, part_count).
  #
  # phase/expand: new table, no backfill. One row per in-flight chunked
  # attachment upload (`Engram.Attachments.Uploads`); deleted on abort, kept
  # (completed_at set) for a day after it completes so a retried complete gets
  # the committed attachment. Ciphertext only: the path is sealed under the DEK and
  # the per-file key is DEK-wrapped, so nothing here is plaintext.
  #
  # RLS mirrors note_revisions: tenant-scoped on user_id, ENABLE + FORCE,
  # engram_app grants, plus maintenance_all.
  def change do
    create table(:attachment_uploads, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :vault_id, references(:vaults, type: :uuid, on_delete: :delete_all), null: false

      # The attachment id this upload commits as, claimed at start (the live
      # row's id for the path, else fresh). Not a FK: the row may not exist yet.
      add :attachment_id, :uuid, null: false

      add :path_hmac, :binary, null: false
      add :path_ciphertext, :binary, null: false
      add :path_nonce, :binary, null: false
      add :mime_type, :text, null: false
      add :size_bytes, :bigint, null: false
      add :mtime, :float
      add :part_size, :integer, null: false
      add :part_count, :integer, null: false
      add :storage_key, :text, null: false
      add :s3_upload_id, :text, null: false
      add :wrapped_file_key, :binary, null: false
      add :file_key_nonce, :binary, null: false
      # users.dek_version the key and path are sealed under. DEK rotation
      # rewraps both and bumps it; complete refuses on a mismatch.
      add :dek_version, :integer, null: false
      # Part number (string key) => storage ETag.
      add :parts, :map, null: false, default: %{}
      # Set once storage has assembled the parts into one object; a retried
      # complete skips re-assembly (the multipart upload no longer exists).
      add :assembled_at, :timestamptz
      # Set in the transaction that commits the attachment (`attachment_id`
      # is then the committed row). A completed session is never written
      # again, only read by a repeat complete and dropped by the expiry sweep.
      add :completed_at, :timestamptz

      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
      add :updated_at, :timestamptz, null: false, default: fragment("now()")
    end

    # RLS predicate, and the on_delete cascades scan them.
    create index(:attachment_uploads, [:user_id])
    create index(:attachment_uploads, [:vault_id])

    execute(
      "ALTER TABLE attachment_uploads ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE attachment_uploads DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE attachment_uploads FORCE ROW LEVEL SECURITY",
      "ALTER TABLE attachment_uploads NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_attachment_uploads ON attachment_uploads
        USING (user_id::text = (SELECT current_setting('app.current_tenant', true)))
        WITH CHECK (user_id::text = (SELECT current_setting('app.current_tenant', true)))
      """,
      "DROP POLICY IF EXISTS tenant_isolation_attachment_uploads ON attachment_uploads"
    )

    execute(
      "CREATE POLICY maintenance_all ON attachment_uploads TO engram_maintenance USING (true) WITH CHECK (true)",
      "DROP POLICY IF EXISTS maintenance_all ON attachment_uploads"
    )

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON attachment_uploads TO engram_app",
      "REVOKE ALL ON attachment_uploads FROM engram_app"
    )
  end
end
