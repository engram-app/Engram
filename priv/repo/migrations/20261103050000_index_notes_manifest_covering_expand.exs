defmodule Engram.Repo.Migrations.IndexNotesManifestCoveringExpand do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  phase/expand: the sync manifest's notes side becomes an index-only scan
  (`EngramWeb.SyncController.manifest_notes/3`, EngramWeb.SyncManifestPlanTest).

  Prod 2026-11-03, a 40k-note vault, cold: the notes side read 9.3k heap
  pages (about 5 rows a page, 0.56 ms a read): 5.5 s. Even warm, a heap walk
  of 40k rows costs ~120-200 ms.

    * `notes_manifest (user_id, vault_id, id) INCLUDE (dek_version, seq,
      content_hash, path_nonce, path_ciphertext)`: every notes column the
      manifest reads. Key ends in `id`, the order of
      `note_bodies_user_note_head (user_id, note_id)`. ~250 B an entry,
      about 40 MB for prod's ~150k live notes, ~1.4k leaf pages for the
      40k vault. Partial on `octet_length(path_ciphertext) <= 2000`: a path
      has no total length cap, and a btree entry over 2,704 bytes (INCLUDE
      columns count) refuses the row's write; with the cap an entry stays
      under ~2.2 KB.
    * `notes_manifest_long_path (user_id, vault_id)`: the rows the cap
      leaves out (near empty), read from the heap by the manifest's second
      half. The manifest states both predicates verbatim.

  Write cost: the INCLUDE columns change with `seq` (already indexed) or a
  path move (path HMAC indexes), so those updates were never HOT. A DEK
  rotation (a rare per-user rewrite of `path_ciphertext`) may now lose HOT
  for its rows. `crdt_head` is deliberately not included
  (head stores stay HOT). Inserts and non-HOT updates write one more entry.

  `notes` vacuums at 2% + 1,000 dead or inserted rows (default 20% + 50,
  20% + 1,000), as 20261102120000 set on `note_bodies`: an index-only scan
  skips the heap only for all-visible pages, and prod's `notes` VM was 74%
  set. Small vacuums usually skip index cleanup (PG's 2% bypass).

  Each index is dropped by name first, so a retry after a failed
  CONCURRENTLY build rebuilds an INVALID index instead of keeping it.
  """

  @live "deleted_at IS NULL AND kind = 'note'"

  def up do
    drop_if_exists index(:notes, [:user_id, :vault_id, :id],
                     name: :notes_manifest,
                     concurrently: true
                   )

    create index(:notes, [:user_id, :vault_id, :id],
             name: :notes_manifest,
             include: [:dek_version, :seq, :content_hash, :path_nonce, :path_ciphertext],
             where: "#{@live} AND octet_length(path_ciphertext) <= 2000",
             concurrently: true
           )

    drop_if_exists index(:notes, [:user_id, :vault_id],
                     name: :notes_manifest_long_path,
                     concurrently: true
                   )

    create index(:notes, [:user_id, :vault_id],
             name: :notes_manifest_long_path,
             where: "#{@live} AND (octet_length(path_ciphertext) <= 2000) IS NOT TRUE",
             concurrently: true
           )

    execute "ALTER TABLE notes SET (autovacuum_vacuum_scale_factor = 0.02, " <>
              "autovacuum_vacuum_threshold = 1000, " <>
              "autovacuum_vacuum_insert_scale_factor = 0.02, " <>
              "autovacuum_vacuum_insert_threshold = 1000)"
  end

  def down do
    execute "ALTER TABLE notes RESET (autovacuum_vacuum_scale_factor, " <>
              "autovacuum_vacuum_threshold, autovacuum_vacuum_insert_scale_factor, " <>
              "autovacuum_vacuum_insert_threshold)"

    drop_if_exists index(:notes, [:user_id, :vault_id],
                     name: :notes_manifest_long_path,
                     concurrently: true
                   )

    drop_if_exists index(:notes, [:user_id, :vault_id, :id],
                     name: :notes_manifest,
                     concurrently: true
                   )
  end
end
