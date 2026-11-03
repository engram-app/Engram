defmodule Engram.Repo.Migrations.DropNotesSyncBodyTriggerDrops do
  use Ecto.Migration

  @moduledoc """
  R8 release N+1 (#2401): drops the `notes_sync_body` trigger and its
  function (20261021110200). Since release N (#2400) every app writer of a
  `notes` body column keeps `note_bodies` in step itself with
  `Engram.Notes.NoteBody.sync!/3`, in the same transaction, and
  `NoteSplit.heal/2` inserts any missing body row the same way, so the
  trigger only writes what `sync!/3` already wrote. Dropping it makes every
  save write the body once instead of copying it through a trigger.

  `notes_derive_core_keys` and `notes_crdt_head_invalidate` stay: they do
  other jobs.

  Skip-release safe: a self-hoster jumping from before N runs N's code
  with this schema, and that code never needed the trigger.

  `down` recreates the function and trigger exactly as 20261021110200 made
  them (copied verbatim: migrations are frozen, so this one cannot call
  that one).
  """

  def up do
    # DROP TRIGGER takes ACCESS EXCLUSIVE on notes for milliseconds; fail
    # fast behind a long transaction instead of queueing every notes write,
    # and let the next boot retry.
    execute "SET lock_timeout = '5s'"
    execute "DROP TRIGGER IF EXISTS notes_sync_body ON notes"
    execute "DROP FUNCTION IF EXISTS notes_sync_body()"
    execute "RESET lock_timeout"
  end

  def down do
    execute "SET lock_timeout = '5s'"

    # format 1 nonce field (13 bytes) starts with 1; a format 0 one (12) gets
    # a leading 0. A NULL nonce means the column already holds that layout.
    # crdt_head is url-safe base64, no padding, of a 32-byte digest.
    execute """
    CREATE FUNCTION notes_sync_body() RETURNS trigger
    LANGUAGE plpgsql SET search_path = '' AS $$
    DECLARE
      has_body boolean := false;
      -- A body column changed when its nonce did (every encryption takes a
      -- fresh one), or, for a merged column (NULL nonce), when its bytes did.
      c_changed boolean := true;
      s_changed boolean := true;
      v_content bytea;
      v_crdt bytea;
      v_head bytea;
    BEGIN
      IF NEW.kind IS DISTINCT FROM 'note' THEN
        RETURN NULL;
      END IF;

      IF TG_OP = 'UPDATE' THEN
        has_body := EXISTS (SELECT 1 FROM public.note_bodies WHERE note_id = NEW.id);
        c_changed := NEW.content_nonce IS DISTINCT FROM OLD.content_nonce
          OR (NEW.content_nonce IS NULL
              AND NEW.content_ciphertext IS DISTINCT FROM OLD.content_ciphertext);
        s_changed := NEW.crdt_state_nonce IS DISTINCT FROM OLD.crdt_state_nonce
          OR (NEW.crdt_state_nonce IS NULL
              AND NEW.crdt_state_ciphertext IS DISTINCT FROM OLD.crdt_state_ciphertext);

        IF has_body AND NOT c_changed AND NOT s_changed
           AND NEW.crdt_head IS NOT DISTINCT FROM OLD.crdt_head
           AND NEW.dek_version IS NOT DISTINCT FROM OLD.dek_version
           AND NEW.user_id IS NOT DISTINCT FROM OLD.user_id THEN
          RETURN NULL;
        END IF;
      END IF;

      IF NOT has_body OR c_changed THEN
        v_content := CASE WHEN NEW.content_ciphertext IS NULL THEN NULL
          WHEN NEW.content_nonce IS NULL THEN NEW.content_ciphertext
          WHEN length(NEW.content_nonce) = 13 THEN NEW.content_nonce || NEW.content_ciphertext
          ELSE '\\x00'::bytea || NEW.content_nonce || NEW.content_ciphertext END;
      END IF;

      IF NOT has_body OR s_changed THEN
        v_crdt := CASE WHEN NEW.crdt_state_ciphertext IS NULL THEN NULL
          WHEN NEW.crdt_state_nonce IS NULL THEN NEW.crdt_state_ciphertext
          WHEN length(NEW.crdt_state_nonce) = 13 THEN NEW.crdt_state_nonce || NEW.crdt_state_ciphertext
          ELSE '\\x00'::bytea || NEW.crdt_state_nonce || NEW.crdt_state_ciphertext END;
      END IF;

      v_head := CASE WHEN NEW.crdt_head ~ '^[A-Za-z0-9_-]{43}$'
        THEN decode(translate(NEW.crdt_head, '-_', '+/') || '=', 'base64') END;

      IF has_body THEN
        UPDATE public.note_bodies b SET
          user_id = NEW.user_id,
          key_version = CASE WHEN NEW.dek_version BETWEEN 0 AND 32767 THEN NEW.dek_version ELSE 0 END,
          content_ct = CASE WHEN c_changed THEN v_content ELSE b.content_ct END,
          crdt_ct = CASE WHEN s_changed THEN v_crdt ELSE b.crdt_ct END,
          crdt_head = v_head
        WHERE b.note_id = NEW.id;

        RETURN NULL;
      END IF;

      INSERT INTO public.note_bodies (note_id, user_id, key_version, content_ct, crdt_ct, crdt_head)
      VALUES (NEW.id, NEW.user_id,
              CASE WHEN NEW.dek_version BETWEEN 0 AND 32767 THEN NEW.dek_version ELSE 0 END,
              v_content, v_crdt, v_head)
      ON CONFLICT (note_id) DO NOTHING;

      RETURN NULL;
    END
    $$
    """

    execute """
    CREATE TRIGGER notes_sync_body
      AFTER INSERT OR UPDATE OF content_ciphertext, content_nonce, crdt_state_ciphertext,
        crdt_state_nonce, crdt_head, dek_version, kind, user_id
      ON notes FOR EACH ROW EXECUTE FUNCTION notes_sync_body()
    """

    execute "RESET lock_timeout"
  end
end
