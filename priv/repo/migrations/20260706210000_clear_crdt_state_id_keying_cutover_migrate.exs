# rollback-irreversible — purged CRDT snapshots cannot be reconstructed;
# `down` raises by design. Pre-launch data is wipeable: the next bind re-seeds
# every note from `notes.content` via the current codec. Take a DB backup
# before deploying if you need a fallback.
defmodule Engram.Repo.Migrations.ClearCrdtStateIdKeyingCutoverMigrate do
  use Ecto.Migration

  # phase/migrate-data — data-only reset; no schema DDL.
  #
  # The id-keyed doc_id cutover (Engram#925, release-v0.5.634) re-keys the CRDT
  # wire doc_id + client keying from `{vault}/{path}` to the bare note_id.
  # Clients (plugin/web) that built rooms and IndexedDB entries under the old
  # path-based doc_id are now orphaned against the new note_id rooms. Any
  # server snapshot or tail-log seeded while the old client keying was live can
  # hand stale state back into a freshly-keyed room, so clear it pre-launch and
  # let every note re-seed cleanly from `notes.content` on next bind.
  #
  # Mechanically identical to the v1->v2 codec wipe
  # (20260629250000_clear_v1_crdt_state_migrate): null the snapshot columns on
  # `notes` AND drain `crdt_update_log` (a surviving tail would replay updates
  # onto a re-seeded doc). This runs on the cutover release tag, whose deploy
  # also rolls every ECS task — dropping the ephemeral in-memory rooms
  # (CrdtRegistry) so nothing re-persists stale state after the purge.
  def up do
    # Both tables carry FORCE ROW LEVEL SECURITY, and the migrator role
    # (`engram_admin` on prod RDS) is the table owner but has neither
    # SUPERUSER nor BYPASSRLS. Migrations set no `app.current_tenant`, so the
    # tenant policy would filter EVERY row and the DML below would silently
    # touch 0 rows on prod — dev/CI masked this because their Docker
    # superuser bypasses RLS regardless of FORCE. Owners bypass RLS unless
    # FORCE, so drop the flag for this transaction: the ACCESS EXCLUSIVE lock
    # keeps app queries out of the unforced window, and FORCE is restored
    # before commit (or by rollback on failure).
    execute("ALTER TABLE notes NO FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE crdt_update_log NO FORCE ROW LEVEL SECURITY")

    execute("UPDATE notes SET crdt_state_ciphertext = NULL, crdt_state_nonce = NULL")
    execute("DELETE FROM crdt_update_log")

    # Fail loud if the purge didn't stick (e.g. a role/ownership change makes
    # the owner bypass ineffective again). A silent partial purge replays stale
    # state onto a re-seeded doc — the exact bug this migration exists to
    # prevent. Runs while NO FORCE is still in effect so the counts see all
    # rows.
    execute("""
    DO $$
    DECLARE remaining bigint;
    BEGIN
      SELECT COUNT(*) INTO remaining FROM notes WHERE crdt_state_ciphertext IS NOT NULL;
      IF remaining > 0 THEN
        RAISE EXCEPTION 'CRDT purge incomplete: % notes still carry crdt_state', remaining;
      END IF;
      SELECT COUNT(*) INTO remaining FROM crdt_update_log;
      IF remaining > 0 THEN
        RAISE EXCEPTION 'CRDT purge incomplete: % crdt_update_log rows remain', remaining;
      END IF;
    END $$;
    """)

    execute("ALTER TABLE notes FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE crdt_update_log FORCE ROW LEVEL SECURITY")
  end

  def down do
    raise "ClearCrdtStateIdKeyingCutoverMigrate is irreversible — purged snapshots cannot be restored"
  end
end
