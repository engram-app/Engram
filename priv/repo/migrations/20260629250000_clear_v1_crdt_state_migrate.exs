# rollback-irreversible — purged v1 CRDT snapshots cannot be reconstructed;
# `down` raises by design. Pre-launch data is wipeable: the next bind re-seeds
# every note from `notes.content` via the v2 codec (frontmatter Y.Map +
# body-only Y.Text). Take a DB backup before deploying if you need a fallback.
defmodule Engram.Repo.Migrations.ClearV1CrdtStateMigrate do
  use Ecto.Migration

  # phase/migrate-data — data-only reset; no schema DDL.
  #
  # The v2 CRDT doc shape (frontmatter in a Y.Map, body-only Y.Text) is
  # incompatible with persisted v1 snapshots (whole file in a single Y.Text
  # content node). Loading v1 state against the v2 codec keeps frontmatter
  # in the body and leaves the per-key Y.Map empty — the new frontmatter
  # CRDT never engages.
  #
  # Fix: clear both the snapshot columns on `notes` AND the `crdt_update_log`
  # tail-log (a surviving tail would replay v1 updates onto a re-seeded v2
  # doc). On next bind, `seed_from_content` routes through the v2 codec and
  # re-seeds from `notes.content` cleanly.
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
    # the owner bypass ineffective again). A silent partial purge replays v1
    # state onto the v2 codec — the exact bug this migration exists to
    # prevent. Runs while NO FORCE is still in effect so the counts see all
    # rows.
    execute("""
    DO $$
    DECLARE remaining bigint;
    BEGIN
      SELECT COUNT(*) INTO remaining FROM notes WHERE crdt_state_ciphertext IS NOT NULL;
      IF remaining > 0 THEN
        RAISE EXCEPTION 'v1 CRDT purge incomplete: % notes still carry crdt_state', remaining;
      END IF;
      SELECT COUNT(*) INTO remaining FROM crdt_update_log;
      IF remaining > 0 THEN
        RAISE EXCEPTION 'v1 CRDT purge incomplete: % crdt_update_log rows remain', remaining;
      END IF;
    END $$;
    """)

    execute("ALTER TABLE notes FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE crdt_update_log FORCE ROW LEVEL SECURITY")
  end

  def down do
    raise "ClearV1CrdtStateMigrate is irreversible — purged snapshots cannot be restored"
  end
end
