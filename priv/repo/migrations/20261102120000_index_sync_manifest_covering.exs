defmodule Engram.Repo.Migrations.IndexSyncManifestCovering do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  Covering indexes so `GET /api/sync/manifest` (`SyncController.manifest_rows/2`)
  and the per-user attachment usage sum (`Attachments.storage_usage/1`) read
  index pages only (EngramWeb.SyncManifestPlanTest).

  Prod 2026-11-02 (engram_app, RLS set): a 40k-note manifest read 40k notes
  heap rows and hash-joined 40k `note_bodies` heap rows for `crdt_head`
  (8k disk reads, 839 ms); a 14.8k-attachment manifest did a bitmap heap
  scan with 1,885 disk reads (38 ms); the usage sum read the same 2,307 heap
  pages on each of 203k calls in 5 days.

    * `notes_manifest`: the manifest's predicate and every notes column it
      returns. Every INCLUDE column already changes only together with `seq`
      (indexed), so no notes update loses HOT; inserts and non-HOT updates
      write one more index entry. `crdt_head` is NOT included: head stores
      update it alone and stay HOT.
    * `note_bodies_user_note_head` replaces `note_bodies_user_note` (same
      keys, plus `crdt_head`). This ends HOT for the body updates that change
      the head (20261031000000 chose HOT over this read; prod measured the
      read at 604 ms). Those updates now write two index entries (pkey and
      this index); body updates that keep the head stay HOT.
    * `attachments_manifest`: the manifest's predicate and columns.
    * `attachments_user_live_size`: the usage sum's predicate and its one
      column (~36 B an entry), so the sum reads a few index pages.
    Attachments are rarely updated, so their visibility map stays set.

  Additive for the previous release (no code names an index). Each index is
  dropped by name first, so a retry after a failed CONCURRENTLY build
  rebuilds an INVALID index instead of skipping it; the replaced index is
  dropped only after its successor is built.
  """

  @indexes [
    {"notes_manifest", "notes",
     "(user_id, vault_id) INCLUDE (id, dek_version, path_ciphertext, path_nonce, content_hash, seq)",
     "deleted_at IS NULL AND kind = 'note'"},
    {"note_bodies_user_note_head", "note_bodies", "(user_id, note_id) INCLUDE (crdt_head)", nil},
    {"attachments_manifest", "attachments",
     "(user_id, vault_id) INCLUDE (id, dek_version, path_ciphertext, path_nonce, content_hash, seq)",
     "deleted_at IS NULL"},
    {"attachments_user_live_size", "attachments", "(user_id) INCLUDE (size_bytes)",
     "deleted_at IS NULL"}
  ]

  def up do
    for {name, table, cols, where} <- @indexes do
      execute "DROP INDEX CONCURRENTLY IF EXISTS #{name}"
      where = if where, do: " WHERE #{where}", else: ""
      execute "CREATE INDEX CONCURRENTLY #{name} ON #{table} #{cols}#{where}"
    end

    execute "DROP INDEX CONCURRENTLY IF EXISTS note_bodies_user_note"
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS note_bodies_user_note"
    execute "CREATE INDEX CONCURRENTLY note_bodies_user_note ON note_bodies (user_id, note_id)"

    for {name, _, _, _} <- @indexes, do: execute("DROP INDEX CONCURRENTLY IF EXISTS #{name}")
  end
end
