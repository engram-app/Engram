# Shared helpers; see each file for why they are not in lib/.
Code.require_file("bounded_index_build.exs", __DIR__)
Code.require_file("migration_log.exs", __DIR__)

defmodule Engram.Repo.Migrations.IndexFoldersParentAllIdsExpand do
  use Ecto.Migration

  alias Engram.Repo.Migrations.{BoundedIndexBuild, MigrationLog}

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  `folders_parent_all_ids`: `folders_live_parent_id`'s key `(vault_id,
  parent_id, id) INCLUDE (user_id)` with no `deleted_at` predicate, for the
  moved-folder feed's subtree walk that includes dead subfolders
  (`Engram.Folders.Rows.descendant_ids/4` with `dead: true`, O(1) folder
  rename plan S5, Engram#2523). `folders_parent (vault_id, parent_id)`
  covers the same rows but not `user_id`, so under RLS each probe needs the
  heap for the tenant check, and the planner walked the tenant's whole
  folder list (`folders_user`) a level instead (`MovedFolderFeedPlanTest`).
  Index-only here.

  One more entry per folder insert and per non-HOT folder update (a move
  changes `parent_id`). `folders_parent` stays: the parent FK's hard-delete
  check needs a non-partial `(vault_id, parent_id)` index. Additive: the
  previous release ignores it. Prod: ~50k folder rows (2026-11-17), a few
  MB, a second or two inside BoundedIndexBuild's 110 s budget. Rerun-safe.
  """

  def up do
    started = MigrationLog.now()

    BoundedIndexBuild.build!(
      repo(),
      [{"folders_parent_all_ids", "ON folders (vault_id, parent_id, id) INCLUDE (user_id)"}],
      lock_key: 20_261_117_020_000,
      label: "index_folders_parent_all_ids"
    )

    MigrationLog.indexes(
      repo(),
      "index_folders_parent_all_ids",
      ["folders_parent_all_ids"],
      started
    )
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS folders_parent_all_ids"
  end
end
