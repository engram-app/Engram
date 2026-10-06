# priv/repo/migrations/20261006120000_create_note_revisions_expand.exs
defmodule Engram.Repo.Migrations.CreateNoteRevisionsExpand do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # squawk run on this file (v2.54.0) reports only two rules, both moot for a
  # table created empty in this same migration: require-concurrent-index-creation
  # (no rows, no writers to block) and prefer-bigint-over-int (dek_version,
  # pending_dek_version, char_count). lint_migrations.sh has no per-rule
  # per-file exclusion, so this follows note_links and vault_index_states. No
  # SET lock_timeout either: .squawk.toml excludes require-timeout-settings and
  # no migration here sets one.
  #
  # phase/expand: new table, no backfill. Note version history (#1710, epic #609).
  #
  # One row per version, meaning one editing session by one actor. A row is
  # OPEN while `closed_at` is NULL, and the open version has no copy of its text
  # anywhere: its text is the note. When a later save starts a new version, that
  # save closes this row and copies the note's OLD content ciphertext into
  # `pending_*` in its own transaction (an outbox). FinalizeRevision moves the
  # copy to object storage and clears it.
  #
  # RLS mirrors vault_index_update_log: tenant-scoped on user_id, ENABLE +
  # FORCE, engram_app grants, plus the maintenance_all policy every tenant table
  # needs (Engram.Repo.MaintenanceRoleTest fails without it).
  def change do
    create table(:note_revisions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")

      add :note_id, references(:notes, type: :uuid, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :vault_id, references(:vaults, type: :uuid, on_delete: :delete_all), null: false

      add :actor, :text, null: false
      add :origin, :text, null: false
      # Unused until teams. One nullable column now beats a migration on a
      # large table later.
      add :actor_user_id, :uuid
      add :restored_from_id, references(:note_revisions, type: :uuid, on_delete: :nilify_all)

      add :session_started_at, :timestamptz, null: false
      add :closed_at, :timestamptz

      # The outbox copy: the note's own content ciphertext, still bound to the
      # notes AAD of note_id. Set when the version closes, cleared by
      # FinalizeRevision.
      add :pending_ciphertext, :binary
      add :pending_nonce, :binary
      add :pending_dek_version, :integer
      # Set when the copy can never decrypt. FinalizeRevision parks the row
      # instead of retrying it forever and blocking the note's later versions.
      add :finalize_failed_at, :timestamptz

      add :storage_key, :text
      add :blob_nonce, :binary
      add :content_hash, :text
      add :char_count, :integer
      add :dek_version, :integer, null: false, default: 2

      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
      add :updated_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:note_revisions, [:note_id],
             where: "closed_at IS NULL",
             name: :note_revisions_one_open_per_note
           )

    create index(:note_revisions, [:note_id, :inserted_at])

    create index(:note_revisions, [:updated_at],
             where: "pending_ciphertext IS NOT NULL AND finalize_failed_at IS NULL",
             name: :note_revisions_pending
           )

    # RLS predicate, and the on_delete cascades scan it.
    create index(:note_revisions, [:user_id])
    # The vault FK cascades too: CleanupVault hard-deletes vaults.
    create index(:note_revisions, [:vault_id])

    execute(
      "ALTER TABLE note_revisions ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE note_revisions DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE note_revisions FORCE ROW LEVEL SECURITY",
      "ALTER TABLE note_revisions NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_note_revisions ON note_revisions
        USING (user_id::text = (SELECT current_setting('app.current_tenant', true)))
        WITH CHECK (user_id::text = (SELECT current_setting('app.current_tenant', true)))
      """,
      "DROP POLICY IF EXISTS tenant_isolation_note_revisions ON note_revisions"
    )

    execute(
      "CREATE POLICY maintenance_all ON note_revisions TO engram_maintenance USING (true) WITH CHECK (true)",
      "DROP POLICY IF EXISTS maintenance_all ON note_revisions"
    )

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON note_revisions TO engram_app",
      "REVOKE ALL ON note_revisions FROM engram_app"
    )
  end
end
