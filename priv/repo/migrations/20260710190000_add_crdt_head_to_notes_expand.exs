defmodule Engram.Repo.Migrations.AddCrdtHeadToNotesExpand do
  use Ecto.Migration

  @moduledoc """
  phase/expand — cheap head index for CrdtTransport.vault_heads.

  `crdt_head` = sha256(state_vector) url-b64 (~43 chars), so a client can diff
  its per-note heads to find cold notes that advanced WITHOUT the server
  rebuilding every note's Y.Doc per poll. INVALIDATE-and-self-heal: it is NULLed
  on every CRDT-state change, and `vault_heads` rebuilds a NULL once (lazily).

  * Tail appends (room edits) — `CrdtPersistence.update_v1` NULLs the head in the
    same txn as the tail-log insert.
  * Snapshot writes (REST create/update via `maybe_merge_crdt`, checkpoint
    compaction) — the trigger below NULLs the head structurally, so NO snapshot
    writer (current or future) can leave a stale head.

  `vault_heads` self-heals a NULL by rebuilding the doc once and storing the
  result (compare-and-set against the tail high-watermark, so a concurrent edit
  can't be clobbered); `Engram.Workers.BackfillCrdtHead` warms existing NULLs.

  :text (not varchar) for Squawk's prefer-text rule; the schema field is
  :string, which Ecto reads from text unchanged. The nullable column add is
  metadata-only on PG11+ (no rewrite); `CREATE TRIGGER` briefly takes a SHARE
  ROW EXCLUSIVE lock on `notes` (blocks writes for the DDL only — fast, not
  lock-free), which is why this is expand-phase and deployed before readers.
  """

  def up do
    alter table(:notes) do
      add :crdt_head, :text
    end

    execute("""
    CREATE OR REPLACE FUNCTION notes_null_crdt_head() RETURNS trigger AS $$
    BEGIN
      NEW.crdt_head := NULL;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    -- Pinned search_path (splinter: function_search_path_mutable). The body
    -- assigns a column only, touching no schema-qualified object.
    SET search_path = '';
    """)

    # BEFORE UPDATE OF crdt_state_ciphertext: the head is derived from the CRDT
    # state, so any change to the snapshot invalidates it. Column-scoped + the
    # IS DISTINCT guard so a no-op write (or an update_v1/self-heal write that
    # touches only crdt_head) never fires it.
    execute("""
    CREATE TRIGGER notes_crdt_head_invalidate
    BEFORE UPDATE OF crdt_state_ciphertext ON notes
    FOR EACH ROW
    WHEN (NEW.crdt_state_ciphertext IS DISTINCT FROM OLD.crdt_state_ciphertext)
    EXECUTE FUNCTION notes_null_crdt_head();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS notes_crdt_head_invalidate ON notes;")
    execute("DROP FUNCTION IF EXISTS notes_null_crdt_head();")

    alter table(:notes) do
      remove :crdt_head
    end
  end
end
