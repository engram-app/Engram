defmodule Engram.Repo.Migrations.CreateFrontmatterKeysAndNoteAttrsExpand do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # Both tables are created empty in this same migration, so
  # require-concurrent-index-creation is moot (no rows, no writers to block);
  # same reasoning as note_revisions and note_links.
  #
  # phase/expand: new tables, no backfill (the v5 indexing pass fills them).
  #
  # Every v5 frontmatter filter value (spec 3.3b, flat fields moved off
  # `notes` by the 2026-10-20 Postgres scale audit): one row per (note, key,
  # value) in an EAV table, `notes` gets no columns or indexes. `key_id` is a
  # small per-user integer: the named fields (type, tags, status, ...) take
  # the reserved ids of `Engram.Notes.FrontmatterKeys`, user-added keys are
  # allocated above them in `frontmatter_keys`, where the key name is kept
  # only as a 32-byte HMAC under the per-user filter key. Exactly one value
  # column is set: `h` (exact values, a 32-byte HMAC), `n` (numbers) or `d`
  # (dates, unix seconds). Numbers and dates are plaintext so they range.
  #
  # RLS mirrors note_revisions: tenant-scoped on user_id, ENABLE + FORCE,
  # engram_app grants, plus the maintenance_all policy every tenant table needs.
  def change do
    create table(:frontmatter_keys, primary_key: false) do
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :key_id, :smallint, null: false, primary_key: true
      add :key_hmac, :binary, null: false
      # The key as first seen (original casing), for a per-vault field
      # catalog: encrypted under the per-user DEK, AAD
      # `aad_for_row(:frontmatter_keys, "name:<key_id>", user_id)`.
      add :name_ct, :binary, null: false
      add :name_nonce, :binary, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:frontmatter_keys, [:user_id, :key_hmac])

    # Columns ordered for alignment (8-byte n/d, then the 2-byte smallints,
    # then the varlena h). `ord` is the value's position in its key's list
    # (0 for a scalar), so (note_id, key_id, ord) is the natural key; the PK
    # also serves the delete-by-note rewrite and the note cascade.
    create table(:note_attrs, primary_key: false) do
      add :note_id, references(:notes, type: :uuid, on_delete: :delete_all),
        null: false,
        primary_key: true

      # No FKs on user_id / vault_id: a user or vault delete reaches these
      # rows through `note_id` (notes cascade from both), so neither needs an
      # index for a cascade scan. user_id is the RLS column; vault_id leads
      # the lookups.
      add :user_id, :uuid, null: false
      add :vault_id, :uuid, null: false
      add :n, :float
      add :d, :bigint
      add :key_id, :smallint, null: false, primary_key: true
      add :ord, :smallint, null: false, primary_key: true
      add :h, :binary
    end

    # Every search is vault-scoped (a multi-vault query is one IN over the
    # user's vault ids), so the lookups lead with vault_id. INCLUDE note_id so
    # the per-vault field catalog (`Engram.Notes.FieldCatalog`: GROUP BY
    # key_id / key_id, h with count(DISTINCT note_id), min/max) is
    # index-only, and user_id because the RLS policy reads it: without it
    # every row the app role scans is a heap fetch, never an index-only scan.
    for col <- ~w(h n d)a do
      create index(:note_attrs, [:vault_id, :key_id, col],
               include: [:note_id, :user_id],
               where: "#{col} IS NOT NULL"
             )
    end

    create constraint(:note_attrs, :note_attrs_one_value, check: "num_nonnulls(h, n, d) = 1")

    for table <- ~w(frontmatter_keys note_attrs) do
      execute(
        "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY",
        "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
      )

      execute(
        "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY",
        "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
      )

      execute(
        """
        CREATE POLICY tenant_isolation_#{table} ON #{table}
          USING (user_id = (SELECT NULLIF((SELECT current_setting('app.current_tenant', true)), '')::uuid))
          WITH CHECK (user_id = (SELECT NULLIF((SELECT current_setting('app.current_tenant', true)), '')::uuid))
        """,
        "DROP POLICY IF EXISTS tenant_isolation_#{table} ON #{table}"
      )

      execute(
        "CREATE POLICY maintenance_all ON #{table} TO engram_maintenance USING (true) WITH CHECK (true)",
        "DROP POLICY IF EXISTS maintenance_all ON #{table}"
      )

      execute(
        "GRANT SELECT, INSERT, UPDATE, DELETE ON #{table} TO engram_app",
        "REVOKE ALL ON #{table} FROM engram_app"
      )
    end
  end
end
