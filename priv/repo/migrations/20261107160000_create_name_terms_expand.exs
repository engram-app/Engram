defmodule Engram.Repo.Migrations.CreateNameTermsExpand do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # Created empty in this same migration, so require-concurrent-index-creation
  # is moot (no rows, no writers to block); same reasoning as chunk_points.
  #
  # phase/expand: a new table, no backfill here (the `NameTerms` ledger
  # DataMigration fills it). The previous release never reads it.
  #
  # `name_terms` (O(1) folder rename plan, S1): a per-token posting list of
  # note titles / filenames (ref_kind 0) and folder names (ref_kind 1). `dim`
  # is the keyword leg's sparse dimension (`QdrantSparse.dim/2` under the
  # user's DEK filter key, folded to a signed int4), so no plaintext token is
  # stored. At most 32 rows per ref (`Engram.Search.NameTerms`).
  #
  # Primary key (vault_id, dim, ref_kind, ref_id): the search leg reads at
  # most 500 postings per query term on its prefix. `name_terms_ref` serves
  # the per-ref replace on rename. A vault delete cascades its rows; a user
  # delete reaches them through its vaults.
  def change do
    create table(:name_terms, primary_key: false, options: "WITH (fillfactor = 90)") do
      add :vault_id, references(:vaults, type: :uuid, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :dim, :integer, null: false, primary_key: true
      add :ref_kind, :smallint, null: false, primary_key: true
      add :ref_id, :uuid, null: false, primary_key: true
      add :user_id, :uuid, null: false
    end

    create index(:name_terms, [:ref_id], name: :name_terms_ref)

    execute(
      "ALTER TABLE name_terms ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE name_terms DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE name_terms FORCE ROW LEVEL SECURITY",
      "ALTER TABLE name_terms NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_name_terms ON name_terms
        USING (user_id = (SELECT NULLIF((SELECT current_setting('app.current_tenant', true)), '')::uuid))
        WITH CHECK (user_id = (SELECT NULLIF((SELECT current_setting('app.current_tenant', true)), '')::uuid))
      """,
      "DROP POLICY IF EXISTS tenant_isolation_name_terms ON name_terms"
    )

    execute(
      "CREATE POLICY maintenance_all ON name_terms TO engram_maintenance USING (true) WITH CHECK (true)",
      "DROP POLICY IF EXISTS maintenance_all ON name_terms"
    )

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON name_terms TO engram_app",
      "REVOKE ALL ON name_terms FROM engram_app"
    )
  end
end
