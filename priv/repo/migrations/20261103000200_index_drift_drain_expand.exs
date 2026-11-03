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

    * `*_envelope_legacy_*`: a format-0 envelope (12-byte nonce, more than the
      16-byte tag), `ReencodeEnvelopes`. `dek_version >= 2` is
      `Crypto.row_version_aad_bound/0` for the note body.
    * `note_index_state_unstamped`: an indexed note with no `payload_hash`,
      `ReconcileNotePayloads`. `chunk_count > 0` stands for "has points".
    * `notes_unresolved_folder`: a live note in a non-root folder whose
      `folder_ref_id` is NULL, `FolderTable`. A root note keeps a NULL
      reference forever and a NOT NULL `folder_hmac` (the HMAC of ""), so the
      root is excluded by its envelope: an empty plaintext is the 16-byte tag.
    * Link keys already have `*_link_keys_stale_index` (20261018230001).

  HOT: on `notes` the predicate columns are `content_nonce`,
  `content_ciphertext`, `crdt_state_*`, `dek_version`, `folder_ciphertext`,
  `folder_ref_id`, `kind`, `deleted_at`. Every write that changes a content or
  state ciphertext also sets `updated_at` (indexed), so it is already not
  heap-only; `folder_ref_id`, `kind` and `deleted_at` are already in other
  indexes; `folder_ciphertext` changes only with `folder_hmac` (indexed) or a
  DEK rotation. On `note_index_state` the predicate columns are `payload_hash`
  and `chunk_count`, written a few times per index run (not per chunk), which
  costs two small index entries on those updates. The three log tables are
  insert-mostly.

  Additive: the previous release ignores them. Each is dropped by name first,
  so a retry after a failed CONCURRENTLY build rebuilds an INVALID index.
  """

  @indexes [
    {"notes_envelope_legacy_content", "notes", "user_id",
     "octet_length(content_nonce) = 12 AND octet_length(content_ciphertext) > 16 AND dek_version >= 2"},
    {"notes_envelope_legacy_crdt", "notes", "user_id",
     "octet_length(crdt_state_nonce) = 12 AND octet_length(crdt_state_ciphertext) > 16"},
    {"crdt_update_log_envelope_legacy", "crdt_update_log", "user_id",
     "octet_length(update_nonce) = 12 AND octet_length(update_ciphertext) > 16"},
    {"vault_index_states_envelope_legacy", "vault_index_states", "user_id",
     "octet_length(state_nonce) = 12 AND octet_length(state_ciphertext) > 16"},
    {"vault_index_update_log_envelope_legacy", "vault_index_update_log", "user_id",
     "octet_length(update_nonce) = 12 AND octet_length(update_ciphertext) > 16"},
    {"note_index_state_unstamped", "note_index_state", "user_id",
     "payload_hash IS NULL AND chunk_count > 0"},
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
