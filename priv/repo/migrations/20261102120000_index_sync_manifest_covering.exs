defmodule Engram.Repo.Migrations.IndexSyncManifestCovering do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  The manifest's `note_bodies` read and the per-user attachment usage sum
  become index-only, and the planner gets per-vault statistics fast enough
  for a key lookup to see a vault's real size (EngramWeb.SyncManifestPlanTest,
  Engram.NotesGenericPlanTest).

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

  Statistics. `SET STATISTICS 1000` on `notes.user_id` / `vault_id` keeps up
  to 1,000 vaults in the most-common-values list (default 100), so a custom
  plan sees a big vault's row count. Analyze sooner (2% of rows + 1,000,
  default 10%): a new vault in its first sync gets stats within a few
  thousand writes. Cost: the larger target makes ANALYZE sample up to 300k
  rows, i.e. read all of `notes` (~237 MB heap, cached), about every 4k
  changed rows.

  Vacuum on `note_bodies` (2% + 1,000 for dead and for inserted rows,
  default 20% + 50 / 1,000): keeps its visibility map fresh, which an
  index-only scan needs to skip the heap. Two indexes, so a run is cheap.
  `notes` keeps the defaults: its manifest read is a heap read now, and a
  vacuum there scans 28 indexes.

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

    execute "ALTER TABLE notes ALTER COLUMN vault_id SET STATISTICS 1000"
    execute "ALTER TABLE notes ALTER COLUMN user_id SET STATISTICS 1000"

    execute "ALTER TABLE notes SET (autovacuum_analyze_scale_factor = 0.02, " <>
              "autovacuum_analyze_threshold = 1000)"

    execute "ALTER TABLE note_bodies SET (autovacuum_vacuum_scale_factor = 0.02, " <>
              "autovacuum_vacuum_threshold = 1000, " <>
              "autovacuum_vacuum_insert_scale_factor = 0.02, " <>
              "autovacuum_vacuum_insert_threshold = 1000)"
  end

  def down do
    execute "ALTER TABLE note_bodies RESET (autovacuum_vacuum_scale_factor, " <>
              "autovacuum_vacuum_threshold, autovacuum_vacuum_insert_scale_factor, " <>
              "autovacuum_vacuum_insert_threshold)"

    execute "ALTER TABLE notes RESET (autovacuum_analyze_scale_factor, autovacuum_analyze_threshold)"
    execute "ALTER TABLE notes ALTER COLUMN user_id SET STATISTICS -1"
    execute "ALTER TABLE notes ALTER COLUMN vault_id SET STATISTICS -1"

    execute "DROP INDEX CONCURRENTLY IF EXISTS note_bodies_user_note"
    execute "CREATE INDEX CONCURRENTLY note_bodies_user_note ON note_bodies (user_id, note_id)"

    for {name, _, _, _} <- @indexes, do: execute("DROP INDEX CONCURRENTLY IF EXISTS #{name}")
  end
end
