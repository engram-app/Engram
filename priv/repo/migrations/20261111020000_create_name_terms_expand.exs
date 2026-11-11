# Shared with 20261111000000; see the file for why it is not in lib/.
Code.require_file("lock_timeout_retry.exs", __DIR__)
Code.require_file("migration_log.exs", __DIR__)

defmodule Engram.Repo.Migrations.CreateNameTermsExpand do
  use Ecto.Migration

  alias Engram.Repo.Migrations.{LockTimeoutRetry, MigrationLog}

  @disable_ddl_transaction true
  @disable_migration_lock true

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
  #
  # Locks: the foreign key takes SHARE ROW EXCLUSIVE on `vaults` (vault
  # writes wait, reads do not). The statements run through `LockTimeoutRetry`:
  # a 5 s `lock_timeout` per statement and a statement that hits it (55P03)
  # retried twice, so a busy `vaults` row does not crash boot. No DDL
  # transaction, so each statement is rerun-safe on its own (IF NOT EXISTS,
  # a policy dropped by name before it is created; RLS enable / force and the
  # grant are idempotent). Constraint names match Ecto's (`name_terms_pkey`,
  # `name_terms_vault_id_fkey`). Calls no app module (N-1 gate).

  def up, do: run_up(repo())
  def down, do: run_down(repo())

  @tenant_policy """
  CREATE POLICY tenant_isolation_name_terms ON name_terms
    USING (user_id = (SELECT NULLIF((SELECT current_setting('app.current_tenant', true)), '')::uuid))
    WITH CHECK (user_id = (SELECT NULLIF((SELECT current_setting('app.current_tenant', true)), '')::uuid))
  """

  @doc false
  # Public for `NameTermsMigrationsLockTest`.
  def run_up(repo) do
    started = MigrationLog.now()
    existed = existed?(repo)

    :ok = build(repo)

    MigrationLog.done(
      "create_name_terms",
      [table_created: if(existed, do: 0, else: 1), policies: policies(repo)],
      started
    )
  end

  defp existed?(repo),
    do: repo.query!("SELECT 1 FROM pg_class WHERE relname = 'name_terms'").num_rows == 1

  defp policies(repo),
    do: repo.query!("SELECT 1 FROM pg_policies WHERE tablename = 'name_terms'").num_rows

  defp build(repo) do
    LockTimeoutRetry.with_lock_timeout(repo, [
      """
      CREATE TABLE IF NOT EXISTS name_terms (
        vault_id uuid NOT NULL,
        dim integer NOT NULL,
        ref_kind smallint NOT NULL,
        ref_id uuid NOT NULL,
        user_id uuid NOT NULL,
        CONSTRAINT name_terms_pkey PRIMARY KEY (vault_id, dim, ref_kind, ref_id),
        CONSTRAINT name_terms_vault_id_fkey FOREIGN KEY (vault_id)
          REFERENCES vaults (id) ON DELETE CASCADE
      ) WITH (fillfactor = 90)
      """,
      "CREATE INDEX IF NOT EXISTS name_terms_ref ON name_terms (ref_id)",
      "ALTER TABLE name_terms ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE name_terms FORCE ROW LEVEL SECURITY",
      "DROP POLICY IF EXISTS tenant_isolation_name_terms ON name_terms",
      @tenant_policy,
      "DROP POLICY IF EXISTS maintenance_all ON name_terms",
      "CREATE POLICY maintenance_all ON name_terms TO engram_maintenance USING (true) WITH CHECK (true)",
      "GRANT SELECT, INSERT, UPDATE, DELETE ON name_terms TO engram_app"
    ])
  end

  @doc false
  def run_down(repo) do
    LockTimeoutRetry.with_lock_timeout(repo, ["DROP TABLE IF EXISTS name_terms"])
  end
end
