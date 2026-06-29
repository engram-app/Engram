defmodule Engram.Repo.Migrations.DbAuditIndexesAndExtensionExpand do
  use Ecto.Migration

  @moduledoc """
  phase/expand — forward-compatible index + extension changes from the
  2026-06-29 DB audit (Engram#792). All CONCURRENTLY (no write-blocking),
  so @disable_ddl_transaction.

  1. crdt_update_log: index the two CASCADE foreign keys (user_id, vault_id).
     They had no covering index, so a vault/user delete would seq-scan this
     append-heavy event log, and the RLS user_id filter couldn't use an index.
  2. client_logs: drop two indexes the audit found never scanned
     (idx_scan = 0): (user_id, level) ~7.5 MB and (user_id, created_at) ~6 MB.
     client_logs is write-heavy (plugin log sink), so these were pure
     write-amplification for zero read benefit.
  3. pg_stat_statements: create the extension (already in the RDS param
     group's shared_preload_libraries, but never CREATE'd, so the stats view
     didn't exist for query-level tuning).

  Dropping an unused index is forward-compatible (no lib/ code references an
  index by name), so this stays in expand, not contract.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "CREATE INDEX CONCURRENTLY IF NOT EXISTS crdt_update_log_user_id_index ON crdt_update_log (user_id)"

    execute "CREATE INDEX CONCURRENTLY IF NOT EXISTS crdt_update_log_vault_id_index ON crdt_update_log (vault_id)"

    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_client_logs_user_level"
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_client_logs_user_created"

    execute "CREATE EXTENSION IF NOT EXISTS pg_stat_statements"
  end

  def down do
    execute "DROP EXTENSION IF EXISTS pg_stat_statements"

    execute "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_client_logs_user_created ON client_logs (user_id, created_at)"

    execute "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_client_logs_user_level ON client_logs (user_id, level)"

    execute "DROP INDEX CONCURRENTLY IF EXISTS crdt_update_log_vault_id_index"
    execute "DROP INDEX CONCURRENTLY IF EXISTS crdt_update_log_user_id_index"
  end
end
