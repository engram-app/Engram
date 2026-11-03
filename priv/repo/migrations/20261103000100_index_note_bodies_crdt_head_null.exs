defmodule Engram.Repo.Migrations.IndexNoteBodiesCrdtHeadNull do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  Also `note_bodies_sizes` (below). `WarmCrdtHeads` finds notes with a NULL `crdt_head` through this index
  instead of walking `notes` (Job Load Audit 2026-11-03, item 4). It holds
  only the NULL-head rows of `note_bodies`, the trigger-kept narrow copy of
  the head, so it is empty-to-small in steady state.

  On `note_bodies`, not `notes`: every CRDT persist NULLs the head, and an
  index whose predicate names `crdt_head` makes that write non-HOT. On `notes`
  that means 24 index entries per persist (`NotesHotAppendTest`); on
  `note_bodies` (primary key and `note_bodies_user_note`) it means two small
  ones. `note_id` is a key column so the candidate read is index-only.

  Additive: the previous release ignores it. Dropped by name first, so a retry
  after a failed CONCURRENTLY build rebuilds an INVALID index.
  """

  def up do
    execute "DROP INDEX CONCURRENTLY IF EXISTS note_bodies_crdt_head_null"

    execute """
    CREATE INDEX CONCURRENTLY note_bodies_crdt_head_null
      ON note_bodies (user_id, note_id) WHERE crdt_head IS NULL
    """

    # `CrdtBloatSweep` reads every live note's stored sizes from here,
    # index-only, instead of the wide body heap. The sizes change only with a
    # body ciphertext, whose write is already not heap-only on this table (the
    # envelope-legacy indexes, 20261103000200), so this adds an index entry to
    # such a write, never a row version.
    execute "DROP INDEX CONCURRENTLY IF EXISTS note_bodies_sizes"

    execute """
    CREATE INDEX CONCURRENTLY note_bodies_sizes
      ON note_bodies (note_id) INCLUDE (content_bytes, state_bytes)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS note_bodies_crdt_head_null"
    execute "DROP INDEX CONCURRENTLY IF EXISTS note_bodies_sizes"
  end
end
