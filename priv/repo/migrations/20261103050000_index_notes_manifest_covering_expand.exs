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

  Write cost: no update that is HOT today stops being HOT. `seq` and
  `content_hash` are already in other indexes' keys or predicates (every
  save bumps `seq`, so every save is already non-HOT), `path_nonce` is in
  `notes_link_keys_stale_index`'s predicate, and every writer of
  `path_ciphertext` or `dek_version` also writes a new `path_nonce`. If a
  contract PR drops that index, this one becomes the only index on
  `path_nonce`; still harmless while every path rewrite also changes `seq`
  or `path_id`. `crdt_head` is deliberately not included (head stores stay
  HOT). Each inserted or non-HOT row writes one more entry here.

  Vacuum: `notes` vacuums at 5% + 1,000 dead rows (default 20% + 50) and
  2% + 1,000 inserted rows (default 20% + 1,000). An index-only scan skips
  the heap only for all-visible pages; prod's `notes` VM was 74% set
  (2026-11-02), so the 40k vault would still fetch ~2.4k heap pages cold.
  20261102120000 kept the defaults because a `notes` vacuum scans every
  index. Prod: ~80.5k updates and ~6.1k inserts a day (stats window 698 h),
  so ~9.3 dead-triggered plus ~1.5 insert-triggered runs a day instead of
  ~2.8. Assume no index-vacuum bypass (Postgres skips it only when pages
  with dead items are under 2% of the table, ~626 pages; not shown for
  ~4.5k non-HOT dead items a run): each run reads the unset part of the
  heap (up to ~64 MB) and all ~250 MB of `notes` indexes, ~3.4 GB a day
  worst case against ~0.85 GB at the defaults. 2% would be ~21 runs,
  ~6.6 GB. The PR's post-deploy checks carry the revert rule.

  Rerun-safe: the reloptions first (cheap, idempotent), then each index
  dropped only if an earlier failed CONCURRENTLY build left it INVALID, and
  built IF NOT EXISTS, so a rerun neither keeps a broken index nor rebuilds
  a good one.
  """

  @live "deleted_at IS NULL AND kind = 'note'"

  @indexes [
    {:notes_manifest, [:user_id, :vault_id, :id],
     include: [:dek_version, :seq, :content_hash, :path_nonce, :path_ciphertext],
     where: "#{@live} AND octet_length(path_ciphertext) <= 2000"},
    {:notes_manifest_long_path, [:user_id, :vault_id],
     where: "#{@live} AND (octet_length(path_ciphertext) <= 2000) IS NOT TRUE"}
  ]

  def up do
    execute "ALTER TABLE notes SET (autovacuum_vacuum_scale_factor = 0.05, " <>
              "autovacuum_vacuum_threshold = 1000, " <>
              "autovacuum_vacuum_insert_scale_factor = 0.02, " <>
              "autovacuum_vacuum_insert_threshold = 1000)"

    # Read before any command runs: Ecto buffers the commands below.
    invalid = Enum.filter(@indexes, fn {name, _, _} -> invalid?(name) end)

    for {name, cols, opts} <- @indexes do
      if Enum.any?(invalid, &(elem(&1, 0) == name)),
        do: drop(index(:notes, cols, name: name, concurrently: true))

      create_if_not_exists index(:notes, cols, [name: name, concurrently: true] ++ opts)
    end
  end

  def down do
    execute "ALTER TABLE notes RESET (autovacuum_vacuum_scale_factor, " <>
              "autovacuum_vacuum_threshold, autovacuum_vacuum_insert_scale_factor, " <>
              "autovacuum_vacuum_insert_threshold)"

    for {name, cols, _} <- Enum.reverse(@indexes),
        do: drop_if_exists(index(:notes, cols, name: name, concurrently: true))
  end

  defp invalid?(name) do
    %{rows: rows} =
      repo().query!(
        "SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid " <>
          "WHERE c.relname = $1 AND NOT i.indisvalid",
        [Atom.to_string(name)],
        log: false
      )

    rows != []
  end
end
