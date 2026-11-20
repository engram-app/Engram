# Shared helpers; see each file for why they are not in lib/.
Code.require_file("bounded_index_build.exs", __DIR__)
Code.require_file("migration_log.exs", __DIR__)

defmodule Engram.Repo.Migrations.IndexFoldersExplicitReadsExpand do
  use Ecto.Migration

  alias Engram.Repo.Migrations.{BoundedIndexBuild, MigrationLog}

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  Two partial `folders` indexes for the explicit-folder reads (S6 step 4,
  Engram#2523). Folder listings (`GET /folders/explicit`, `GET /folders`,
  `GET /vault/tree`, the MCP folder counts) read explicit folders from
  `folders.explicit` instead of the `kind = 'folder'` marker rows
  (`Engram.Folders.Rows.explicit_rows/3`): O(explicit folders) a listing,
  as the marker read's `notes_folder_marker` was.

    * `folders_explicit_vault_live (vault_id) INCLUDE (user_id, id)` over
      live explicit rows: index-only under the RLS policy.
    * `folders_explicit_user_vault (user_id, vault_id)` over explicit rows
      (live or not, so a delete's tombstone is no churn). The reads bind
      `user_id` and `vault_id` (`Rows.scoped/2`), so it takes both as its
      condition. With only the first, a partial index holding dead entries
      (rolled back or deleted, between autovacuums) is costed as a read of
      all its pages and the planner read `folders_user (user_id)`, every
      folder of the tenant (#2639's CI; a local probe at 0 and 20,000 dead
      rows). With this one the reads stay on a vault-bound explicit index
      at 0 to 20,000 dead rows, custom and generic. Its predicate holds
      `explicit`, which the folder walk never filters on, so a walk probe
      cannot use it (a full `(user_id, vault_id)` index broke the walk:
      `WalkIndexCondTest`, #2639's CI at 7867bc47f).

  Additive: the previous release ignores them. Both predicates hold
  `explicit`, so a write that flips the flag (a create or delete of an empty
  folder, rare) is not heap-only; a content save never touches a folder
  row. Prod: ~47k folder rows (2026-11-16), far fewer explicit; each
  CONCURRENTLY build is two heap passes, seconds, under SHARE UPDATE
  EXCLUSIVE (reads and writes go on), inside BoundedIndexBuild's budget.
  Rerun-safe: an INVALID leftover is dropped and rebuilt. Replaces the
  never-merged versions 20261118130000, 20261118210000, 20261118220000 and
  20261118230000; a database that ran one keeps its index, unused, and
  nothing drops it (the migration gates refuse a drop).
  """

  @indexes [
    {"folders_explicit_vault_live",
     "ON folders (vault_id) INCLUDE (user_id, id) WHERE explicit AND deleted_at IS NULL"},
    {"folders_explicit_user_vault", "ON folders (user_id, vault_id) WHERE explicit"}
  ]

  def up do
    started = MigrationLog.now()

    BoundedIndexBuild.build!(repo(), @indexes,
      lock_key: 20_261_118_235_000,
      label: "index_folders_explicit_reads"
    )

    MigrationLog.indexes(
      repo(),
      "index_folders_explicit_reads",
      Enum.map(@indexes, &elem(&1, 0)),
      started
    )
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS folders_explicit_user_vault"
    execute "DROP INDEX CONCURRENTLY IF EXISTS folders_explicit_vault_live"
  end
end
