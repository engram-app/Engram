# Shared helpers; see each file for why they are not in lib/.
Code.require_file("bounded_index_build.exs", __DIR__)
Code.require_file("migration_log.exs", __DIR__)

defmodule Engram.Repo.Migrations.IndexFoldersVaultReadsExpand do
  use Ecto.Migration

  alias Engram.Repo.Migrations.{BoundedIndexBuild, MigrationLog}

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  Two `folders` indexes that keep a vault's folder reads bounded to the
  vault, whichever one the planner picks (S6 step 4, Engram#2523):

    * `folders_explicit_vault_live`: a vault's live explicit folders.
      Folder listings (`GET /folders/explicit`, `GET /folders`,
      `GET /vault/tree`, the MCP folder counts) read explicit folders from
      `folders.explicit` instead of the `kind = 'folder'` marker rows
      (`Engram.Folders.Rows.explicit_rows/3`): O(explicit folders) a
      listing, as the marker read's `notes_folder_marker` was. `user_id`
      and `id` are INCLUDEd so the read is index-only under the RLS policy.
    * `folders_user_vault`: every folder row of a tenant's vault. A partial
      index that has gathered dead entries (rolled-back or deleted explicit
      rows, between autovacuums) is costed as a read of all its pages, and
      then the planner read `folders_user (user_id)`: every folder of the
      tenant, all vaults (#2639's CI, and a local probe from 1,500 dead
      rows on). With the reads binding `user_id` and `vault_id`
      (`Rows.scoped/2`), this index takes both as its condition, so the
      fallback reads one vault's folders, never the tenant's.

  Additive: the previous release ignores them. `folders_explicit_vault_live`
  holds `explicit` in its predicate, so a write that flips the flag (rare)
  is not heap-only; `folders_user_vault` keys on columns no update changes,
  so it costs one index entry per folder insert and none per update. Prod:
  ~47k folder rows (2026-11-16); each CONCURRENTLY build is two heap
  passes, seconds, under SHARE UPDATE EXCLUSIVE (reads and writes go on),
  inside BoundedIndexBuild's budget. Rerun-safe: an INVALID leftover is
  dropped and rebuilt. Replaces the never-merged versions 20261118130000
  and 20261118210000 (`folders_explicit_live`, `folders_explicit_live_v2`);
  a database that ran either keeps that index, unused, and nothing drops
  it (the migration gates refuse a drop).
  """

  @indexes [
    {"folders_explicit_vault_live",
     "ON folders (vault_id) INCLUDE (user_id, id) WHERE explicit AND deleted_at IS NULL"},
    {"folders_user_vault", "ON folders (user_id, vault_id)"}
  ]

  def up do
    started = MigrationLog.now()

    BoundedIndexBuild.build!(repo(), @indexes,
      lock_key: 20_261_118_220_000,
      label: "index_folders_vault_reads"
    )

    MigrationLog.indexes(
      repo(),
      "index_folders_vault_reads",
      Enum.map(@indexes, &elem(&1, 0)),
      started
    )
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS folders_user_vault"
    execute "DROP INDEX CONCURRENTLY IF EXISTS folders_explicit_vault_live"
  end
end
