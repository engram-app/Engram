defmodule Engram.Repo.Migrations.ObanJobsReindexReadyExpand do
  use Ecto.Migration

  # 1. fillfactor back to the default 100. 20261021090000 set 85 so state
  #    transitions could be HOT updates, but every Oban update changes `state`,
  #    which is indexed, so none can be (prod 2026-11-03: 3,088 HOT of 8.78M
  #    updates). It only left 15% of each page empty. A storage parameter:
  #    SHARE UPDATE EXCLUSIVE, blocks no read or write, applies to new pages.
  #
  # 2. MAINTAIN on oban_jobs for engram_app, the runtime role, so
  #    `Oban.Reindexer` (`Engram.Jobs.reindexer/0`) may REINDEX it. Only the owner
  #    could before. MAINTAIN is Postgres 17+; on older servers, and on
  #    installs that connect as the owner (self-host), there is nothing to do,
  #    so both are guarded and the migration needs no operator step anywhere.
  #    MAINTAIN also allows VACUUM, ANALYZE, CLUSTER, REFRESH and LOCK TABLE on
  #    this one non-tenant table, nothing else.
  def up do
    execute "ALTER TABLE oban_jobs RESET (fillfactor)"
    execute maintain_sql("GRANT MAINTAIN ON TABLE oban_jobs TO engram_app")
  end

  def down do
    execute maintain_sql("REVOKE MAINTAIN ON TABLE oban_jobs FROM engram_app")
    execute "ALTER TABLE oban_jobs SET (fillfactor = 85)"
  end

  # EXECUTE so a pre-17 server never plans the statement.
  defp maintain_sql(statement) do
    """
    DO $$
    BEGIN
      IF current_setting('server_version_num')::int >= 170000
         AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'engram_app') THEN
        EXECUTE '#{statement}';
      END IF;
    END $$
    """
  end
end
