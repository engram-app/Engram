defmodule Engram.Repo.Migrations.IndexNotesCoreKeys do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  Wave 3 index set (`docs/context/notes-chunks-hyperopt.md` 3.1) on the
  narrow keys of 20261021110000: led by `vault_id` (the vault determines the
  user; RLS filters `user_id`, it is never an index condition), 16-byte
  uuid keys instead of 32-byte HMACs, and partial on liveness wherever
  every reader is live-only, so tombstones and folder rows are not indexed.

  Lookups move here once the `NoteSplit` ledger is done
  (`Engram.Notes.Keys`); until then they read the HMAC indexes. Those are
  dropped in a later release, with the columns, so this one carries both
  sets.

  The feed index `(vault_id, seq, id)` already exists
  (`notes_vault_id_seq_id_index`). `notes_link_keys_stale` inlines the
  current Unicode version code (15.1 -> 1501), as `notes_link_keys_stale_index`
  inlines its stamp: Postgres uses a partial index only for a query carrying
  the same literal (`Engram.Links`).

  Each index is dropped by name first, so a retry after a failed CONCURRENTLY
  build rebuilds an INVALID one instead of skipping it.
  """

  @live_note "deleted_at IS NULL AND NOT is_folder"

  def up do
    indexes = [
      {:notes_path_live, "UNIQUE", "(vault_id, path_id)", @live_note},
      {:notes_path_tomb, "", "(vault_id, path_id, seq)", "deleted_at IS NOT NULL"},
      {:notes_basename, "", "(vault_id, basename_id, path_len) INCLUDE (link_keys_v)",
       @live_note},
      {:notes_path_ci, "", "(vault_id, path_ci_id)", @live_note},
      # Not partial: the marker lookup reads tombstoned markers too (it
      # undeletes one rather than minting a second).
      {:notes_folder, "", "(vault_id, folder_id)", nil},
      {:notes_folder_marker, "UNIQUE", "(vault_id, folder_id)",
       "deleted_at IS NULL AND is_folder"},
      {:notes_type, "", "(vault_id, type_id)", "type_id IS NOT NULL AND deleted_at IS NULL"},
      {:notes_link_keys_stale, "", "(vault_id, basename_id)",
       "basename_id IS NOT NULL AND link_keys_v IS DISTINCT FROM 1501"}
    ]

    for {name, unique, cols, where} <- indexes do
      execute "DROP INDEX CONCURRENTLY IF EXISTS #{name}"
      where = if where, do: " WHERE #{where}", else: ""
      execute "CREATE #{unique} INDEX CONCURRENTLY #{name} ON notes #{cols}#{where}"
    end
  end

  def down do
    for name <- ~w(notes_link_keys_stale notes_type notes_folder_marker notes_folder
                   notes_path_ci notes_basename notes_path_tomb notes_path_live) do
      execute "DROP INDEX CONCURRENTLY IF EXISTS #{name}"
    end
  end
end
