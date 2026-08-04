defmodule Engram.Repo.Migrations.CreateNoteLinksExpand do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # phase/expand — new empty table; indexes created non-CONCURRENTLY are safe
  # because there are zero rows at creation time.
  #
  # WHY. One row per wikilink/embed occurrence in a note (issue #591). Edges are
  # keyed by note UUIDs so renames never invalidate them. target_note_id NULL =
  # dangling link; target_basename_hmac is the only resolution lookup key
  # (case-insensitive Obsidian rules make full-path HMACs unusable). Raw typed
  # target/alias/anchor are encrypted, AAD-bound per row (T3.6 pattern).
  def change do
    create table(:note_links, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :vault_id, references(:vaults, type: :uuid, on_delete: :delete_all), null: false
      add :source_note_id, references(:notes, type: :uuid, on_delete: :delete_all), null: false
      add :target_note_id, references(:notes, type: :uuid, on_delete: :nilify_all)

      add :target_attachment_id,
          references(:attachments, type: :uuid, on_delete: :nilify_all)

      add :target_text_ciphertext, :binary, null: false
      add :target_text_nonce, :binary, null: false
      add :target_basename_hmac, :binary, null: false
      add :link_type, :text, null: false
      add :alias_ciphertext, :binary
      add :alias_nonce, :binary
      add :anchor_ciphertext, :binary
      add :anchor_nonce, :binary
      add :position, :integer, null: false
      add :dek_version, :integer, null: false, default: 2
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create constraint(:note_links, :note_links_link_type_check,
             check: "link_type IN ('wikilink', 'embed')"
           )

    create unique_index(:note_links, [:source_note_id, :position])
    create index(:note_links, [:user_id, :vault_id, :source_note_id])

    # FK column leads so each index also covers its foreign key (splinter
    # unindexed_foreign_keys). All queries filter these columns by equality,
    # so column order doesn't change lookup performance.
    create index(:note_links, [:target_note_id, :user_id, :vault_id])
    create index(:note_links, [:target_attachment_id, :user_id, :vault_id])
    create index(:note_links, [:vault_id])

    # No WHERE clause — `Links.bind_danglers_for_hmac/3` deliberately scans
    # bound edges too (a shorter-path newcomer can steal an existing
    # binding), so a dangling-only partial index would never serve that query.
    create index(:note_links, [:user_id, :vault_id, :target_basename_hmac],
             name: :note_links_basename_idx
           )

    execute(
      "ALTER TABLE note_links ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE note_links DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE note_links FORCE ROW LEVEL SECURITY",
      "ALTER TABLE note_links NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_note_links ON note_links
        USING (user_id::text = (SELECT current_setting('app.current_tenant', true)))
        WITH CHECK (user_id::text = (SELECT current_setting('app.current_tenant', true)))
      """,
      "DROP POLICY IF EXISTS tenant_isolation_note_links ON note_links"
    )

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON note_links TO engram_app",
      "REVOKE ALL ON note_links FROM engram_app"
    )
  end
end
