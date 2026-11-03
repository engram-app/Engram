defmodule Engram.Repo.Migrations.IndexSyncManifestCovering do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  The manifest's `note_bodies` read and the per-user attachment usage sum
  become index-only (EngramWeb.SyncManifestPlanTest).

  Prod 2026-11-02 (engram_app, RLS set), 40k-note vault: the manifest
  hash-joined every `note_bodies` heap row of the user for `crdt_head`
  (8k disk reads, 604 of 839 ms); the usage sum read 2,307 attachments heap
  pages on each of 203k calls in 5 days.

  Indexes. No `path_ciphertext` in any of them: a path has no total length
  cap, and a btree entry over ~2.7 KB would refuse the row's write (or
  this build). The manifest reads `notes` and `attachments` from the heap.

    * `note_bodies_user_note_head` replaces `note_bodies_user_note` (same
      keys, plus the fixed 32-byte `crdt_head`). This ends HOT for the body
      updates that change the head (20261031000000 chose HOT over this
      read): each writes two index entries (pkey and this index).
    * `attachments_user_live_size`: the usage sum (`user_id` prefix) reads
      it alone; `vault_id` is a key so the manifest's `(user_id, vault_id)`
      read can use it too instead of tying with it.

  Additive for the previous release (no code names an index; the settings
  are reloptions). Each index is dropped by name first, so a retry after a
  failed CONCURRENTLY build rebuilds an INVALID index instead of skipping
  it; the replaced index is dropped only after its successor is built.
  """

  @indexes [
    {"note_bodies_user_note_head", "note_bodies", "(user_id, note_id) INCLUDE (crdt_head)", nil},
    {"attachments_user_live_size", "attachments", "(user_id, vault_id) INCLUDE (size_bytes)",
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
