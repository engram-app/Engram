defmodule Engram.Repo.Migrations.DbAuditIndexesAndExtensionExpand do
  use Ecto.Migration

  @moduledoc """
  phase/expand — forward-compatible index + extension changes from the
  2026-06-29 DB audit (Engram#792). All index ops are CONCURRENTLY (no
  write-blocking), so @disable_ddl_transaction.

  1. client_logs: the audit found two indexes never scanned for reads
     (idx_scan = 0) — (user_id, level) ~7.5 MB and (user_id, created_at)
     ~6 MB — on a write-heavy log sink. But both *led* with user_id and were
     the only cover for the `client_logs_user_id_fkey` FK (incl. its ON DELETE
     CASCADE). So replace them with a single narrow client_logs(user_id):
     keeps the FK + cascade covered (splinter), drops the unused level/
     created_at columns, halves per-insert index maintenance.
  2. pg_stat_statements: create the extension in a dedicated `extensions`
     schema (already in the RDS param group's shared_preload_libraries but
     never CREATE'd; splinter flags extensions installed in `public`).

  Deferred from the original audit bundle:
    - crdt_update_log(user_id, vault_id) FK indexes — crdt_update_log is not
      in the previous release-v* tag yet, so the n1-compat gate (apply new
      migrations on the prev release's schema) can't see the table, and
      CONCURRENTLY can't be made conditional. Ships once CRDT is in a release.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "CREATE INDEX CONCURRENTLY IF NOT EXISTS client_logs_user_id_index ON client_logs (user_id)"
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_client_logs_user_level"
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_client_logs_user_created"

    execute "CREATE SCHEMA IF NOT EXISTS extensions"
    execute "CREATE EXTENSION IF NOT EXISTS pg_stat_statements SCHEMA extensions"
  end

  def down do
    execute "DROP EXTENSION IF EXISTS pg_stat_statements"

    execute "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_client_logs_user_created ON client_logs (user_id, created_at)"

    execute "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_client_logs_user_level ON client_logs (user_id, level)"

    execute "DROP INDEX CONCURRENTLY IF EXISTS client_logs_user_id_index"
  end
end
