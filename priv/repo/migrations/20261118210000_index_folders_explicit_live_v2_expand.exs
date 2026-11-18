# Shared helpers; see each file for why they are not in lib/.
Code.require_file("bounded_index_build.exs", __DIR__)
Code.require_file("migration_log.exs", __DIR__)

defmodule Engram.Repo.Migrations.IndexFoldersExplicitLiveV2Expand do
  use Ecto.Migration

  alias Engram.Repo.Migrations.{BoundedIndexBuild, MigrationLog}

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  `folders_explicit_live_v2`: a vault's live explicit folders (S6 step 4,
  Engram#2523). Folder listings (`GET /folders/explicit`, `GET /folders`,
  `GET /vault/tree`, the MCP folder counts) read explicit folders from
  `folders.explicit` instead of the `kind = 'folder'` marker rows
  (`Engram.Folders.Rows.explicit_rows/3`), so this is the index the marker
  read had (`notes_folder_marker`): O(explicit folders) a listing, not a
  read of every folder row of the vault. Keyed `(user_id, vault_id)`, as
  the reads bind both (`Rows.scoped/2`): a narrowing of `folders_user` to
  the live explicit rows, so the planner can never cost the tenant's whole
  folder index below it (#2639's CI read `folders_user`, every folder of
  the tenant, on a `(vault_id)`-keyed version). `id` is INCLUDEd so the
  read is index-only. `_v2` at a new version: a database that ran the
  earlier `(vault_id)`-keyed `folders_explicit_live` (version
  20261118130000, never merged) builds this one too and keeps that one,
  unused; nothing drops it (the migration gates refuse a drop).

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
        {"folders_explicit_live_v2",
         "ON folders (user_id, vault_id) INCLUDE (id) WHERE explicit AND deleted_at IS NULL"}
      ],
      lock_key: 20_261_118_210_000,
      label: "index_folders_explicit_live_v2"
    )

    MigrationLog.indexes(
      repo(),
      "index_folders_explicit_live_v2",
      ["folders_explicit_live_v2"],
      started
    )
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS folders_explicit_live_v2"
  end
end
