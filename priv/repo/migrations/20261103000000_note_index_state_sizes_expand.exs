defmodule Engram.Repo.Migrations.NoteIndexStateSizesExpand do
  use Ecto.Migration

  @moduledoc """
  Stored-size columns on `note_index_state`, kept by triggers, so the hourly
  `CrdtBloatSweep` reads this narrow row instead of aggregating every wide
  `notes` row (prod 2026-11-03: that aggregate took 14,982 ms against the
  15 s query timeout and swapped the database).

  Sizes come from `note_bodies`, not the `notes` body columns, which the R8
  contract stops writing and drops: `content_ct` / `crdt_ct` are `nonce field
  (13 bytes) || ciphertext`, so the stored payload is `octet_length - 13 - 16`
  (the AEAD tag), floored at 0, exactly what the sweep computed from `notes`.
  `octet_length` reads the varlena header, never de-TOASTs. `state_bytes` is 0
  and `has_state` false for a note with no CRDT state.

  Two triggers, because the facts live on two tables:

    * `note_bodies_sync_sizes` (AFTER INSERT OR UPDATE OF content_ct, crdt_ct
      on `note_bodies`) writes the three size columns, whoever writes the body.
    * `notes_sync_sizes` (AFTER INSERT OR UPDATE OF deleted_at, version,
      updated_at, kind on `notes`, named after `notes_sync_index_state` so the
      state row exists) mirrors liveness, version and `updated_at`, and fills
      the sizes from the body row only while they are still NULL: on a note
      insert the body row is written before the state row, so the body
      trigger found no state row to update.

  Both update only when a value changed, and neither changes an indexed
  column of `note_index_state` (fillfactor 80), so the updates stay HOT.
  Additive and nullable: the previous release ignores the columns, and
  `NoteSizes` (data migration) fills rows written before the triggers.
  """

  # One definition of "stored payload bytes of a merged body column", used by
  # both triggers and the `NoteSizes` backfill: `octet_length - 13` (the nonce
  # field) `- 16` (`Envelope.tag_bytes/0`, pinned by `crdt_bloat_sweep_narrow_test`).
  defp size(col), do: "public.note_body_payload_bytes(#{col})"

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
    CREATE FUNCTION note_body_payload_bytes(ct bytea) RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path = '' AS $$
      SELECT greatest(octet_length(ct) - 29, 0)
    $$
    """

    execute """
    CREATE FUNCTION note_bodies_sync_sizes() RETURNS trigger
    LANGUAGE plpgsql SET search_path = '' AS $$
    BEGIN
      UPDATE public.note_index_state s SET
        content_bytes = #{size("NEW.content_ct")},
        state_bytes = #{size("NEW.crdt_ct")},
        has_state = NEW.crdt_ct IS NOT NULL
      WHERE s.note_id = NEW.note_id
        AND (s.content_bytes, s.state_bytes, s.has_state) IS DISTINCT FROM
            (#{size("NEW.content_ct")}, #{size("NEW.crdt_ct")}, NEW.crdt_ct IS NOT NULL);
      RETURN NULL;
    END
    $$
    """

    execute """
    CREATE TRIGGER note_bodies_sync_sizes
      AFTER INSERT OR UPDATE OF content_ct, crdt_ct ON note_bodies
      FOR EACH ROW EXECUTE FUNCTION note_bodies_sync_sizes()
    """

    # COALESCE evaluates its fallback only when the size is still NULL, so the
    # body row is read once per note, on its first write.
    execute """
    CREATE FUNCTION notes_sync_sizes() RETURNS trigger
    LANGUAGE plpgsql SET search_path = '' AS $$
    BEGIN
      UPDATE public.note_index_state s SET
        note_live = NEW.deleted_at IS NULL,
        note_version = NEW.version,
        note_updated_at = NEW.updated_at,
        content_bytes = coalesce(s.content_bytes,
          (SELECT #{size("b.content_ct")} FROM public.note_bodies b WHERE b.note_id = NEW.id)),
        state_bytes = coalesce(s.state_bytes,
          (SELECT #{size("b.crdt_ct")} FROM public.note_bodies b WHERE b.note_id = NEW.id)),
        has_state = coalesce(s.has_state,
          (SELECT b.crdt_ct IS NOT NULL FROM public.note_bodies b WHERE b.note_id = NEW.id))
      WHERE s.note_id = NEW.id AND (
        (s.note_live, s.note_version, s.note_updated_at)
          IS DISTINCT FROM (NEW.deleted_at IS NULL, NEW.version, NEW.updated_at)
        OR s.content_bytes IS NULL);
      RETURN NULL;
    END
    $$
    """

    execute """
    CREATE TRIGGER notes_sync_sizes
      AFTER INSERT OR UPDATE OF deleted_at, version, updated_at, kind
      ON notes FOR EACH ROW WHEN (NEW.kind = 'note')
      EXECUTE FUNCTION notes_sync_sizes()
    """

    execute "RESET lock_timeout"
  end

  def down do
    execute "DELETE FROM data_migrations WHERE name = 'note_sizes'"
    execute "DROP TRIGGER IF EXISTS notes_sync_sizes ON notes"
    execute "DROP FUNCTION IF EXISTS notes_sync_sizes()"
    execute "DROP TRIGGER IF EXISTS note_bodies_sync_sizes ON note_bodies"
    execute "DROP FUNCTION IF EXISTS note_bodies_sync_sizes()"
    execute "DROP FUNCTION IF EXISTS note_body_payload_bytes(bytea)"

    execute """
    ALTER TABLE note_index_state
      DROP COLUMN IF EXISTS content_bytes, DROP COLUMN IF EXISTS state_bytes,
      DROP COLUMN IF EXISTS has_state, DROP COLUMN IF EXISTS note_live,
      DROP COLUMN IF EXISTS note_version, DROP COLUMN IF EXISTS note_updated_at
    """
  end
end
