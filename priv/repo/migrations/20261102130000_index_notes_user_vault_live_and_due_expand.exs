defmodule Engram.Repo.Migrations.IndexNotesUserVaultLiveAndDueExpand do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  phase/expand: two partial indexes on `notes`, no schema change.

    * `notes_user_vault_live (user_id, vault_id) WHERE deleted_at IS NULL`:
      every live row of one vault, both kinds. The whole-vault reads that do not state
      `kind = 'note'` (folder counts, tag counts, unresolved folder rows)
      had no index of that shape and borrowed
      `notes_user_id_vault_id_basename_hmac_index` (prod 2026-11-02: 11 MB,
      ~277 scans/h, none from a basename lookup). Both columns, as the
      queries (and RLS) state them: with `vault_id` alone the planner costs
      the HMAC index's two equalities as more selective and keeps it. One
      key per vault, so btree deduplication stores each vault's rows as a
      posting list (about 6 bytes a row): about 1 MB on prod's ~150k live
      rows, against the HMAC index's 11 MB. That index becomes droppable with the HMAC set
      once nothing else reads it (`NotesWholeVaultPlanTest` pins these
      callers here first).
    * `notes_reconcile_due_v2 (updated_at)`: `notes_reconcile_due` without a
      budget-parked note whose content is unchanged. Those notes wait for
      `WakeBudgetParked` (scheduled at the time the bucket can pay), yet
      every unwindowed `ReconcileEmbeddings` sweep read and rejected each of
      them (prod: 1,662 entries, all parked). The sweep states the extra
      clause verbatim, so a generic plan can use this index; it then reads
      the notes that can be due, not every parked one. `notes_reconcile_due`
      stays for the previous release's sweep; it is droppable (contract)
      once this release is the oldest that runs.

  Write cost: both predicates name only columns other `notes` indexes
  already read (`vault_id`, `deleted_at`, `kind`, `updated_at`, the embed
  hashes, `embed_budget_parked`), so no update that was HOT stops being HOT.
  A non-HOT write adds one entry to `notes_user_vault_live` (every live row) and
  to `notes_reconcile_due_v2` only while the note is in the embed backlog.

  Each index is dropped by name first, so a retry after a failed
  CONCURRENTLY build rebuilds an INVALID index instead of keeping it.
  """

  @due "kind = 'note' AND deleted_at IS NULL AND " <>
         "(embed_hash IS NULL OR embed_hash <> content_hash OR dense_indexed_hash IS NULL) AND " <>
         "(embed_budget_parked IS NOT TRUE OR embed_hash IS DISTINCT FROM content_hash)"

  def up do
    drop_if_exists index(:notes, [:user_id, :vault_id],
                     name: :notes_user_vault_live,
                     concurrently: true
                   )

    create index(:notes, [:user_id, :vault_id],
             name: :notes_user_vault_live,
             where: "deleted_at IS NULL",
             concurrently: true
           )

    drop_if_exists index(:notes, [:updated_at], name: :notes_reconcile_due_v2, concurrently: true)

    create index(:notes, [:updated_at],
             name: :notes_reconcile_due_v2,
             where: @due,
             concurrently: true
           )
  end

  def down do
    drop_if_exists index(:notes, [:updated_at], name: :notes_reconcile_due_v2, concurrently: true)

    drop_if_exists index(:notes, [:user_id, :vault_id],
                     name: :notes_user_vault_live,
                     concurrently: true
                   )
  end
end
