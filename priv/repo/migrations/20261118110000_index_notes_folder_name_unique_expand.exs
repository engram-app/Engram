# Shared helpers; see each file for why they are not in lib/.
Code.require_file("bounded_index_build_v2.exs", __DIR__)
Code.require_file("migration_log.exs", __DIR__)

defmodule Engram.Repo.Migrations.IndexNotesFolderNameUniqueExpand do
  use Ecto.Migration

  alias Engram.Repo.Migrations.{BoundedIndexBuildV2, MigrationLog}

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  S6 step 2 (Engram#2523): `notes_folder_name_unique`, UNIQUE
  `(vault_id, folder_ref_id, name_hmac)` over live notes whose name keys
  are current (`name_key IS NOT NULL`: the `notes_set_name_key` trigger
  keeps it NULL while `folder_ref_id` is NULL or the name stamp is stale).
  The collision guard by folder row and exact name that replaces
  `notes_path_live` once stored paths go (step 7). Exact case (Todd
  2026-11-12): two names differing only by case may share a folder.

  Root notes are covered once step 1b's `root_refs` ledger has pointed them
  at the root row (a NULL reference is never in this index). A stale name
  is out of the index until the `note_name` ledger heals it, so a stale
  hash never collides with a current one.

  A duplicate fails the build loudly at boot (the 0.79.0 lesson): this
  ships only after the prod duplicate probe (PR body) read 0 rows. Prod:
  ~200k notes, an index of ~45 bytes a row, seconds inside the 110 s
  budget. Additive: no release reads it; writers that keep paths unique
  keep names unique (same folder row, same exact name = same path).
  Rerun-safe.
  """

  def up do
    started = MigrationLog.now()

    BoundedIndexBuildV2.build!(
      repo(),
      [
        {"notes_folder_name_unique",
         "ON notes (vault_id, folder_ref_id, name_hmac) " <>
           "WHERE deleted_at IS NULL AND kind = 'note' AND name_key IS NOT NULL", unique: true}
      ],
      lock_key: 20_261_118_110_000,
      label: "index_notes_folder_name_unique"
    )

    MigrationLog.indexes(
      repo(),
      "index_notes_folder_name_unique",
      ["notes_folder_name_unique"],
      started
    )
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS notes_folder_name_unique"
  end
end
