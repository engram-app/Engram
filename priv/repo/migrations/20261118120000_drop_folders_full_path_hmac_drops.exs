# safety_assured: "folders.full_path_hmac: no lib/ code reads or writes it since S6 step 3 phase 2 (the release before this one, the rollback floor); the column is out of the Folder schema"

# Shared helpers; see each file for why they are not in lib/.
Code.require_file("lock_timeout_retry.exs", __DIR__)
Code.require_file("bounded_index_build.exs", __DIR__)

defmodule Engram.Repo.Migrations.DropFoldersFullPathHmacDrops do
  use Ecto.Migration

  alias Engram.Repo.Migrations.{BoundedIndexBuild, LockTimeoutRetry}

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  S6 step 3, phase 3 (Engram#2523): drops `folders.full_path_hmac` and its
  index `folders_full_path` (20261029000000). The HMAC of a folder's whole
  path, kept so a writer could find a folder row by path. From S6 step 3's
  read switch (release D) every reader finds a folder by walking its chain
  of names (`Engram.Folders.Rows`); from its write stop (release E) nothing
  writes it and the column is out of the `Folder` schema. So N-1 (E) never
  names it, and the rollback floor must be at E or later before this ships.

  No data gate: the value is derived (a hash of names the rows still hold),
  so nothing is lost; `down` does not refill it, since nothing reads it.

  The index goes first, CONCURRENTLY (writes keep running), so the column
  drop does not take it under ACCESS EXCLUSIVE. DROP COLUMN is then a
  catalog change, no rewrite. Both under LockTimeoutRetry's 5 s
  `lock_timeout`, retried twice. Rerun-safe through IF EXISTS. Calls no app
  module.

  `down` restores the nullable column (empty) and its partial index, built
  through BoundedIndexBuild like every index here.
  """

  def up do
    LockTimeoutRetry.with_lock_timeout(repo(), [
      "DROP INDEX CONCURRENTLY IF EXISTS folders_full_path",
      "ALTER TABLE folders DROP COLUMN IF EXISTS full_path_hmac"
    ])
  end

  def down do
    LockTimeoutRetry.with_lock_timeout(repo(), [
      "ALTER TABLE folders ADD COLUMN IF NOT EXISTS full_path_hmac bytea"
    ])

    BoundedIndexBuild.build!(
      repo(),
      [
        {"folders_full_path",
         "ON folders (vault_id, full_path_hmac) " <>
           "WHERE full_path_hmac IS NOT NULL AND deleted_at IS NULL"}
      ],
      lock_key: 20_261_118_120_000,
      label: "drop_folders_full_path_hmac_down"
    )
  end
end
