# Shared helpers; see each file for why they are not in lib/.
Code.require_file("bounded_index_build.exs", __DIR__)
Code.require_file("migration_log.exs", __DIR__)

defmodule Engram.Repo.Migrations.IndexFoldersExplicitLiveExpand do
  use Ecto.Migration

  alias Engram.Repo.Migrations.{BoundedIndexBuild, MigrationLog}

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  `folders_explicit_live`: a vault's live explicit folders (S6 step 4,
  Engram#2523). Folder listings (`GET /folders/explicit`, `GET /folders`,
  `GET /vault/tree`, the MCP folder counts) read explicit folders from
  `folders.explicit` instead of the `kind = 'folder'` marker rows
  (`Engram.Folders.Rows.explicit_rows/2`), so this is the index the marker
  read had (`notes_folder_marker`): O(explicit folders) a listing, not a
  read of every folder row of the vault. `user_id` and `id` are INCLUDEd so
  the read is index-only under the RLS policy.

  Additive: the previous release ignores it. Its predicate holds `explicit`,
  so a write that flips the flag (a marker create or delete, rare) is not
  heap-only; a content save never touches a folder row. Prod: ~47k folder
  rows (2026-11-16), a far smaller partial index; the CONCURRENTLY build is
  two heap passes, seconds, under SHARE UPDATE EXCLUSIVE (reads and writes
  go on), inside BoundedIndexBuild's budget. Rerun-safe: an INVALID leftover
  is dropped and rebuilt.
  """

  def up do
    started = MigrationLog.now()

    BoundedIndexBuild.build!(
      repo(),
      [
        {"folders_explicit_live",
         "ON folders (vault_id) INCLUDE (user_id, id) WHERE explicit AND deleted_at IS NULL"}
      ],
      lock_key: 20_261_118_130_000,
      label: "index_folders_explicit_live"
    )

    MigrationLog.indexes(
      repo(),
      "index_folders_explicit_live",
      ["folders_explicit_live"],
      started
    )
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS folders_explicit_live"
  end
end
