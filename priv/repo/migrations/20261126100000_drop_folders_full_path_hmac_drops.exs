# Shared helper; see the file for why it is not in lib/.
Code.require_file("lock_timeout_retry.exs", __DIR__)

defmodule Engram.Repo.Migrations.DropFoldersFullPathHmacDrops do
  @moduledoc """
  phase/contract, release K (S6 step 3, Engram#2523): drops
  `folders_full_path` (vault_id, full_path_hmac), then
  `folders.full_path_hmac`. Release J stopped every read and write of both
  (`Engram.Folders.FullPathHmacRetiredTest`) and the rollback floor is J,
  so no release that can run or be rolled back to names them.

  Skip-release safe on a single-node install: J's boot migration
  20261125100100, the last reader of the column, sorts before this one, so
  a jump from release E..I applies it first, in the same batch. A
  multi-node install must not run a pre-J node beside this release (it
  would read the dropped column).

  1. `DROP INDEX CONCURRENTLY`: SHARE UPDATE EXCLUSIVE, so reads and writes
     go on; it waits for transactions open on `folders`. A cancelled drop
     leaves the index INVALID, which the rerun drops (IF EXISTS).
  2. `DROP COLUMN`: a catalog change (no rewrite; nothing else names the
     column) under ACCESS EXCLUSIVE, held for milliseconds.

  Both run through `LockTimeoutRetry` (as 20261119100200): a 5 s
  `lock_timeout`, retried twice, so behind a long transaction a boot fails
  fast instead of queueing every `folders` read, and only then raises (the
  next boot retries; both IF EXISTS, rerun-safe). `down` restores the
  column nullable and empty, and its index.
  """
  use Ecto.Migration

  alias Engram.Repo.Migrations.LockTimeoutRetry

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    LockTimeoutRetry.with_lock_timeout(repo(), [
      "DROP INDEX CONCURRENTLY IF EXISTS folders_full_path",
      "ALTER TABLE folders DROP COLUMN IF EXISTS full_path_hmac"
    ])
  end

  def down do
    LockTimeoutRetry.with_lock_timeout(repo(), [
      "ALTER TABLE folders ADD COLUMN IF NOT EXISTS full_path_hmac bytea",
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS folders_full_path " <>
        "ON folders (vault_id, full_path_hmac) " <>
        "WHERE full_path_hmac IS NOT NULL AND deleted_at IS NULL"
    ])
  end
end
