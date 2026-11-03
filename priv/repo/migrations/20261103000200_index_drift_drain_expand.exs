defmodule Engram.Repo.Migrations.IndexDriftDrainExpand do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  Partial indexes whose predicate IS a "this row has drifted" test, so the
  5-minute `BookkeepingDrain` finds the drifted users with a few index pages
  instead of the daily re-verify walking every row (Job Load Audit
  2026-11-03, item 1). Each holds only drifted rows: empty in steady state.

  Their predicates are the data-migration workers' own selection predicates,
  inlined as literals (Postgres uses a partial index only for a query carrying
  the same text; `drift_drain_test.exs` pins each match):

    * `*_envelope_legacy`: a format-0 envelope (12-byte nonce, more than the
      16-byte tag), `ReencodeEnvelopes`. A note's body and CRDT state are read
      from `note_bodies` (the copy the R8 contract keeps) through its
      `envelope_legacy` flag, set by the `note_bodies_sizes` BEFORE trigger
      (20261103000000) from the same test on the merged nonce field.
    * `note_index_state_unstamped`: an indexed note with no `payload_hash`,
      `ReconcileNotePayloads`. `points` is the chunk counter the chunks
      triggers keep exact (`chunk_count` is set only on floored or merged notes).
    * `notes_unresolved_folder`: a live note in a non-root folder whose
      `folder_ref_id` is NULL, `FolderTable`. A root note keeps a NULL
      reference forever and a NOT NULL `folder_hmac` (the HMAC of ""), so the
      root is excluded by its envelope: an empty plaintext is the 16-byte tag.
    * Link keys already have `*_link_keys_stale_index` (20261018230001).

  HOT: on `notes` the only new predicate column is `folder_ciphertext`, which
  changes only with `folder_hmac` (indexed) or a DEK rotation; `folder_ref_id`,
  `kind` and `deleted_at` are already in other indexes. On `note_bodies` the
  predicate is the `envelope_legacy` flag, not the ciphertext: it stays false
  across ordinary saves, so body writes stay heap-only (an expression over
  `content_ct` would make every one non-HOT). On `note_index_state` the predicate columns are `payload_hash`
  and `points`: an index run's chunk statements and its stamp are no longer
  heap-only there (two small index entries each); a content edit with no index
  run does not touch them. The three log tables are
  insert-mostly.

  Additive: the previous release ignores them. Each is dropped by name first,
  so a retry after a failed CONCURRENTLY build rebuilds an INVALID index.
  """

  @indexes [
    {"note_bodies_envelope_legacy", "note_bodies", "user_id", "envelope_legacy"},
    {"crdt_update_log_envelope_legacy", "crdt_update_log", "user_id",
     "octet_length(update_nonce) = 12 AND octet_length(update_ciphertext) > 16"},
    {"vault_index_states_envelope_legacy", "vault_index_states", "user_id",
     "octet_length(state_nonce) = 12 AND octet_length(state_ciphertext) > 16"},
    {"vault_index_update_log_envelope_legacy", "vault_index_update_log", "user_id",
     "octet_length(update_nonce) = 12 AND octet_length(update_ciphertext) > 16"},
    {"note_index_state_unstamped", "note_index_state", "user_id",
     "payload_hash IS NULL AND points > 0"},
    {"notes_unresolved_folder", "notes", "user_id",
     "kind = 'note' AND deleted_at IS NULL AND folder_ref_id IS NULL AND octet_length(folder_ciphertext) > 16"}
  ]

  def up do
    for {name, table, cols, predicate} <- @indexes do
      execute "DROP INDEX CONCURRENTLY IF EXISTS #{name}"
      execute "CREATE INDEX CONCURRENTLY #{name} ON #{table} (#{cols}) WHERE #{predicate}"
    end
  end

  def down do
    for {name, _, _, _} <- @indexes, do: execute("DROP INDEX CONCURRENTLY IF EXISTS #{name}")
  end
end
