defmodule Engram.Repo.Migrations.CreateNoteBodies do
  use Ecto.Migration

  @moduledoc """
  Wave 3, expand step (`docs/context/notes-chunks-hyperopt.md` 2.2): a note's
  body (materialized content, CRDT state, manifest head) in its own 1:1
  table, so the core row the listings, manifest, feed and link scans read is
  ~0.5 KB instead of carrying ~16 KB of TOAST pointers and inline bodies.

  Kept in step with `notes` by the `notes_sync_body` trigger (next
  migration) on every write, and for existing rows by the `NoteSplit` data
  migration. Nothing reads it until that ledger is done.

    * `content_ct`, `crdt_ct`: `nonce || ciphertext` in one column. A format 1
      nonce field is 13 bytes starting with 1; a format 0 one (12 bytes) gets
      a leading 0, so the first byte always says where the ciphertext starts
      (`Engram.Crypto.Envelope.split_merged/1`).
    * `crdt_head`: the 32-byte head digest (`notes.crdt_head` is its 43-char
      url-safe base64).
    * `key_version`: the row's DEK version, for the AAD.

  One index (the primary key) and fillfactor 75: a p50 body is a ~2 KB inline
  tuple, three per page, and the slack lets a checkpoint update it in place
  (HOT) with no index entry. STORAGE EXTERNAL on the two bodies: they are
  zstd-compressed before encryption, so TOAST's own lz4 gains nothing.
  `user_id` carries no FK or index: RLS only, and the note_id cascade
  deletes the row.
  """

  def up do
    # key_version is a DEK version (bounded), so int2 cannot overflow.
    execute """
    CREATE TABLE note_bodies (
      note_id uuid PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
      -- squawk-ignore prefer-bigint-over-smallint
      user_id uuid NOT NULL, key_version smallint NOT NULL,
      content_ct bytea,
      crdt_ct bytea,
      crdt_head bytea
    ) WITH (fillfactor = 75)
    """

    execute "ALTER TABLE note_bodies ALTER COLUMN content_ct SET STORAGE EXTERNAL"
    execute "ALTER TABLE note_bodies ALTER COLUMN crdt_ct SET STORAGE EXTERNAL"

    execute "ALTER TABLE note_bodies ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE note_bodies FORCE ROW LEVEL SECURITY"

    execute """
    CREATE POLICY tenant_isolation_note_bodies ON note_bodies
      USING (user_id = (SELECT NULLIF((SELECT current_setting('app.current_tenant', true)), '')::uuid))
      WITH CHECK (user_id = (SELECT NULLIF((SELECT current_setting('app.current_tenant', true)), '')::uuid))
    """

    execute """
    CREATE POLICY maintenance_all ON note_bodies TO engram_maintenance
      USING (true) WITH CHECK (true)
    """

    execute "GRANT SELECT, INSERT, UPDATE, DELETE ON note_bodies TO engram_app"
  end

  def down do
    execute "DROP TABLE note_bodies"
  end
end
