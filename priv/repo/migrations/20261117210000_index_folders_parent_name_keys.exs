# Shared helpers; see each file for why they are not in lib/.
Code.require_file("bounded_index_build.exs", __DIR__)
Code.require_file("migration_log.exs", __DIR__)

defmodule Engram.Repo.Migrations.IndexFoldersParentNameKeys do
  use Ecto.Migration

  alias Engram.Repo.Migrations.{BoundedIndexBuild, MigrationLog}

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  `folders_parent_name_ids (vault_id, parent_id, name_hmac, id) INCLUDE
  (user_id, deleted_at)`, replacing `folders_parent (vault_id, parent_id)`
  and `folders_parent_all_ids (vault_id, parent_id, id) INCLUDE (user_id)`
  (dropped by the next migration, `DropFoldersParentOnlyKeys`, so the parent
  FK always has a covering index).

  The live folder walk (`Engram.Folders.WalkSql`, behind
  `Rows.ids_by_path/3`) must be one probe a level. On a table whose pages
  are not all-visible (staging 0.87.1 after a deploy, row 11c) the name
  index's index-only scan costs a heap page like any other, and the
  planner, estimating one row for `(vault_id, parent_id)` alone, picked a
  parent-only index and read every sibling until the name matched. With
  `name_hmac` keyed after `parent_id` in every non-partial parent index,
  whichever the planner picks keys the name. INCLUDE `deleted_at` keeps the
  live walk's probe index-only on this one too.

  The `(vault_id, parent_id)` prefix still serves the parent FK's check (a
  hard delete) and the dead-row subtree walk (`Rows.descendant_ids/4` with
  `dead: true`, index-only). Additive: the previous release names none of
  these. Prod: ~50k folder rows (2026-11-17), seconds inside
  BoundedIndexBuild's 110 s budget. Rerun-safe.
  """

  def up do
    started = MigrationLog.now()

    BoundedIndexBuild.build!(
      repo(),
      [
        {"folders_parent_name_ids",
         "ON folders (vault_id, parent_id, name_hmac, id) INCLUDE (user_id, deleted_at)"}
      ],
      lock_key: 20_261_117_210_000,
      label: "index_folders_parent_name_ids"
    )

    MigrationLog.indexes(
      repo(),
      "index_folders_parent_name_ids",
      ["folders_parent_name_ids"],
      started
    )
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS folders_parent_name_ids"
  end
end
