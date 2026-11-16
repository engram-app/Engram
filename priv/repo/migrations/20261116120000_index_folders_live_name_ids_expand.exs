# Shared helpers; see each file for why they are not in lib/.
Code.require_file("bounded_index_build.exs", __DIR__)
Code.require_file("migration_log.exs", __DIR__)

defmodule Engram.Repo.Migrations.IndexFoldersLiveNameIdsExpand do
  use Ecto.Migration

  alias Engram.Repo.Migrations.{BoundedIndexBuild, MigrationLog}

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  `folders_live_name_ids`: `folders_live_name`'s key `(vault_id, parent_id,
  name_hmac)` with `user_id` and `id` INCLUDEd, so a folder walk probe
  (`Engram.Folders.WalkSql`) is an index-only scan: the RLS policy's
  `user_id` and the selected `id` come from the index, no heap page.

  Why (staging 0.87.0, 2026-11-16): below the root each walk probe read
  `folders_live_parent_id` with `name_hmac` only a Filter, reading every
  sibling (O(siblings) a level). The planner treats `vault_id` and
  `parent_id` as independent (1,436 rows x 1/8 vaults x 1/412 parents =
  0.43, clamped to 1 row), so that scan is estimated at the same one row
  and one heap page as the unique probe: 8.30 vs 8.43, the gap only btree
  height (the churned `folders_live_name`, 615 pages for 1,406 entries, is
  one level taller). More vaults and parents only lower that estimate.
  Same plan as superuser, so not RLS. An index-only probe saves the heap
  page (about 4.0 of the 8.3), a margin no plain scan of another index
  ties while the table is mostly all-visible (staging 577 of 607 pages).

  Accepted risk: the margin rests on the visibility map. Right after a
  CLUSTER, VACUUM FULL or restore (relallvisible near 0) an index-only scan
  is costed like a heap read and the tie can return until autovacuum sets
  the map again.

  ponytail: not UNIQUE. `folders_live_name` stays the uniqueness
  constraint (insert `on_conflict`, `FolderTableTest`), and
  `BoundedIndexBuild` is frozen to plain `CREATE INDEX`. The cost is one
  more index entry per folder insert and per non-HOT folder update (staging:
  2,263 of 3,213 updates); HOT-ness is unchanged, as every key column is
  already in `folders_live_name`. Upgrade
  path: build this as UNIQUE NULLS NOT DISTINCT and drop `folders_live_name`
  in a later contract step. `folders_parent` stays: the FK
  `folders_parent_fk` checks on a hard delete need a non-partial
  `(vault_id, parent_id)` index.

  No key or included column changes on a content save, so no save stops
  being heap-only. Additive: the previous release plans on it or ignores
  it, both correct. Prod: ~47k rows (2026-11-16), a ~5 MB index; the
  CONCURRENTLY build is two heap passes, a second or two, under SHARE
  UPDATE EXCLUSIVE (reads and writes go on), inside BoundedIndexBuild's
  110 s budget. Rerun-safe: an INVALID leftover is dropped and rebuilt.
  """

  def up do
    started = MigrationLog.now()

    BoundedIndexBuild.build!(
      repo(),
      [
        {"folders_live_name_ids",
         "ON folders (vault_id, parent_id, name_hmac) INCLUDE (user_id, id) " <>
           "WHERE deleted_at IS NULL"}
      ],
      lock_key: 20_261_116_120_000,
      label: "index_folders_live_name_ids"
    )

    MigrationLog.indexes(
      repo(),
      "index_folders_live_name_ids",
      ["folders_live_name_ids"],
      started
    )
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS folders_live_name_ids"
  end
end
