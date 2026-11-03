defmodule Engram.Repo.Migrations.NoteIndexStateSizesExpand do
  use Ecto.Migration

  @moduledoc """
  Stored-size columns on `note_index_state`, kept by a trigger, so the hourly
  `CrdtBloatSweep` reads this narrow row instead of aggregating every wide
  `notes` row (prod 2026-11-03: that aggregate took 14,982 ms against the
  15 s query timeout and swapped the database).

  Stored sizes are `octet_length(ciphertext) - 16` (the AEAD tag), floored at
  0, exactly what the sweep computed from `notes`. `octet_length` reads the
  varlena header, so the trigger never de-TOASTs. `state_bytes` is 0 and
  `has_state` false for a note with no CRDT state. The trigger also mirrors
  `deleted_at` (as `note_live`), `version` and `updated_at`, the other columns
  the sweep reads.

  Additive and nullable: the previous release ignores the columns, and
  `NoteSizes` (data migration) fills rows written before the trigger. The
  trigger is AFTER, named after `notes_sync_index_state`, so the state row
  exists when it runs; it updates only when a value changed. The UPDATE
  changes no indexed column of `note_index_state`, so it stays HOT
  (fillfactor 80).
  """

  def up do
    execute "SET lock_timeout = '5s'"

    # Stored byte sizes of one note (far below 2 GB) and a mirror of notes.updated_at,
    # which is timestamp without time zone.
    execute """
    -- squawk-ignore prefer-bigint-over-int, prefer-timestamptz
    ALTER TABLE note_index_state
      ADD COLUMN IF NOT EXISTS content_bytes integer,
      ADD COLUMN IF NOT EXISTS state_bytes integer,
      ADD COLUMN IF NOT EXISTS has_state boolean,
      ADD COLUMN IF NOT EXISTS note_live boolean,
      ADD COLUMN IF NOT EXISTS note_version integer,
      ADD COLUMN IF NOT EXISTS note_updated_at timestamp
    """

    execute """
    CREATE FUNCTION notes_sync_sizes() RETURNS trigger
    LANGUAGE plpgsql SET search_path = '' AS $$
    BEGIN
      UPDATE public.note_index_state s SET
        content_bytes = greatest(octet_length(NEW.content_ciphertext) - 16, 0),
        state_bytes = greatest(octet_length(NEW.crdt_state_ciphertext) - 16, 0),
        has_state = NEW.crdt_state_ciphertext IS NOT NULL,
        note_live = NEW.deleted_at IS NULL,
        note_version = NEW.version,
        note_updated_at = NEW.updated_at
      WHERE s.note_id = NEW.id AND (
        s.content_bytes, s.state_bytes, s.has_state, s.note_live, s.note_version, s.note_updated_at
      ) IS DISTINCT FROM (
        greatest(octet_length(NEW.content_ciphertext) - 16, 0),
        greatest(octet_length(NEW.crdt_state_ciphertext) - 16, 0),
        NEW.crdt_state_ciphertext IS NOT NULL, NEW.deleted_at IS NULL, NEW.version, NEW.updated_at
      );
      RETURN NULL;
    END
    $$
    """

    execute """
    CREATE TRIGGER notes_sync_sizes
      AFTER INSERT OR UPDATE OF content_ciphertext, crdt_state_ciphertext, deleted_at, version,
        updated_at, kind
      ON notes FOR EACH ROW WHEN (NEW.kind = 'note')
      EXECUTE FUNCTION notes_sync_sizes()
    """

    execute "RESET lock_timeout"
  end

  def down do
    execute "DELETE FROM data_migrations WHERE name = 'note_sizes'"
    execute "DROP TRIGGER IF EXISTS notes_sync_sizes ON notes"
    execute "DROP FUNCTION IF EXISTS notes_sync_sizes()"

    execute """
    ALTER TABLE note_index_state
      DROP COLUMN IF EXISTS content_bytes, DROP COLUMN IF EXISTS state_bytes,
      DROP COLUMN IF EXISTS has_state, DROP COLUMN IF EXISTS note_live,
      DROP COLUMN IF EXISTS note_version, DROP COLUMN IF EXISTS note_updated_at
    """
  end
end
