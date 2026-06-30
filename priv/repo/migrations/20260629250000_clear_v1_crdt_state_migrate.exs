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
  #
  # DELETE is used (not TRUNCATE) so the operation runs inside the migration
  # transaction and respects RLS row-level policies on `crdt_update_log`.
  def up do
    execute("UPDATE notes SET crdt_state_ciphertext = NULL, crdt_state_nonce = NULL")
    execute("DELETE FROM crdt_update_log")
  end

  def down do
    raise "ClearV1CrdtStateMigrate is irreversible — purged snapshots cannot be restored"
  end
end
