defmodule Engram.Repo.Migrations.CreateNoteAttrsExpand do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # The table is created empty in this same migration, so
  # require-concurrent-index-creation is moot (no rows, no writers to block);
  # same reasoning as note_revisions and note_links.
  #
  # phase/expand: new table, no backfill (the v5 indexing pass fills it).
  #
  # The long tail of v5 frontmatter filters (spec 3.3b `fm_attrs` / `fm_nums` /
  # `fm_dates`): one row per (note, key, value). Keys and string values are
  # 32-byte HMACs under the per-user filter key; numbers and dates plaintext
  # (dates unix seconds). Exactly one of value_hmac / value_num / value_date is
  # set. RLS mirrors note_revisions: tenant-scoped on user_id, ENABLE + FORCE,
  # engram_app grants, plus the maintenance_all policy every tenant table needs.
  def change do
    create table(:note_attrs, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :note_id, references(:notes, type: :uuid, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :key_hmac, :binary, null: false
      add :value_hmac, :binary
      add :value_num, :float
      add :value_date, :bigint
    end

    create index(:note_attrs, [:user_id, :key_hmac, :value_hmac], where: "value_hmac IS NOT NULL")
    create index(:note_attrs, [:user_id, :key_hmac, :value_num], where: "value_num IS NOT NULL")
    create index(:note_attrs, [:user_id, :key_hmac, :value_date], where: "value_date IS NOT NULL")
    create index(:note_attrs, [:note_id])
    # The users FK cascades: account deletion scans it. Also the RLS predicate.
    create index(:note_attrs, [:user_id])

    create constraint(:note_attrs, :note_attrs_one_value,
             check: "num_nonnulls(value_hmac, value_num, value_date) = 1"
           )

    execute(
      "ALTER TABLE note_attrs ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE note_attrs DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE note_attrs FORCE ROW LEVEL SECURITY",
      "ALTER TABLE note_attrs NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_note_attrs ON note_attrs
        USING (user_id::text = (SELECT current_setting('app.current_tenant', true)))
        WITH CHECK (user_id::text = (SELECT current_setting('app.current_tenant', true)))
      """,
      "DROP POLICY IF EXISTS tenant_isolation_note_attrs ON note_attrs"
    )

    execute(
      "CREATE POLICY maintenance_all ON note_attrs TO engram_maintenance USING (true) WITH CHECK (true)",
      "DROP POLICY IF EXISTS maintenance_all ON note_attrs"
    )

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON note_attrs TO engram_app",
      "REVOKE ALL ON note_attrs FROM engram_app"
    )
  end
end
