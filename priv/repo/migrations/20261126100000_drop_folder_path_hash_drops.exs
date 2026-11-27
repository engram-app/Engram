# Shared helper (down only); see the file for why it is not in lib/.
Code.require_file("lock_timeout_retry.exs", __DIR__)

defmodule Engram.Repo.Migrations.DropFolderPathHashDrops do
  @moduledoc """
  phase/contract, release K (S6 step 3, Engram#2523): drops
  `folders_full_path` (vault_id, full_path_hmac), then
  `folders.full_path_hmac`. Release J stopped every read and write of both
  (`Engram.Folders.FullPathHmacRetiredTest`) and the rollback floor is J.

  `up` is a no-op guard. The DDL is `@statements`, run AFTER the migrations
  by `Engram.Release.FolderHashDrop` (from `Engram.Release.migrate/0`, on the
  same migrator connection), which can never fail or block boot: a lock it
  cannot get in 5 s is a warning, its ledger stays open and the next boot
  retries. A boot migration cannot do that: a migration that swallowed the
  timeout would be recorded as applied and never retried, and one that
  raises crash-loops new tasks under sustained contention (the 0.79.0 class).

  The statements live HERE, not in `lib/`, on purpose: the migration-gates
  contract-references check (`mix engram.migration_drops`) reads the string
  literals of a migration's up side, maps `ALTER TABLE folders DROP COLUMN
  IF EXISTS full_path_hmac` to `column folders full_path_hmac`, and fails if
  `lib/` still names the column. `lib/` stays free of it: the boot step parses
  this file for the `@statements` literals (it never loads it), so keep them
  one literal list.

  Skip-release safe on a single-node install: J's boot migration
  20261125100100, the last reader of the column, runs in the same batch,
  before the step. A multi-node install must not run a pre-J node beside
  this release. `down` restores the column nullable and empty, and its
  index.
  """
  use Ecto.Migration

  alias Engram.Repo.Migrations.LockTimeoutRetry

  @disable_ddl_transaction true
  @disable_migration_lock true

  # In order: the index without blocking writes, then the column (a catalog
  # change, no rewrite, ACCESS EXCLUSIVE for milliseconds).
  @statements [
    "DROP INDEX CONCURRENTLY IF EXISTS folders_full_path",
    "ALTER TABLE folders DROP COLUMN IF EXISTS full_path_hmac"
  ]

  @doc false
  def statements, do: @statements

  def up, do: :ok

  def down do
    LockTimeoutRetry.with_lock_timeout(repo(), [
      "ALTER TABLE folders ADD COLUMN IF NOT EXISTS full_path_hmac bytea",
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS folders_full_path " <>
        "ON folders (vault_id, full_path_hmac) " <>
        "WHERE full_path_hmac IS NOT NULL AND deleted_at IS NULL"
    ])
  end
end
