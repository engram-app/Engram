defmodule Engram.Repo.Migrations.NotesSplitTriggers do
  use Ecto.Migration

  @moduledoc """
  Wave 3 dual-write, in the database so it covers EVERY writer: this
  release's code, the previous release's nodes during a rolling deploy, raw
  SQL and the backfills. Nothing in the app writes the new columns.

    * `notes_derive_core_keys` (BEFORE INSERT/UPDATE OF the source columns):
      fills the narrow core columns of 20261021110000 from the ones they
      replace. A write that lists none of the sources does not fire it, so a
      metadata-only update stays as HOT as it was.
    * `notes_sync_body` (AFTER INSERT/UPDATE OF the body columns): keeps
      `note_bodies` in step. A body column is rewritten only when its NONCE
      changed: every encryption takes a fresh nonce, so that names a new
      ciphertext without comparing (and de-TOASTing) the bytes, and an
      untouched column keeps its TOAST pointer.

  The `NoteSplit` data migration fills rows written before this by touching
  `kind` (both triggers list it).

  Every function pins `search_path = ''` (splinter:
  function_search_path_mutable), so every name in a body is qualified.

  Every helper is total: a malformed source yields NULL, never an error,
  so no write can fail on a derived column.
  """

  def up do
    execute """
    CREATE FUNCTION notes_hmac_id(h bytea) RETURNS uuid
    LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path = '' AS $$
      SELECT CASE WHEN length(h) >= 16
                  THEN encode(substring(h FROM 1 FOR 16), 'hex')::uuid END
    $$
    """

    # nonce || ct, the first byte telling where the ciphertext starts: a
    # format 1 nonce field (13 bytes) starts with 1; a format 0 one (12) gets
    # a leading 0. A NULL nonce means the column already holds that layout.
    execute """
    CREATE FUNCTION notes_merge_envelope(nonce bytea, ct bytea) RETURNS bytea
    LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path = '' AS $$
      SELECT CASE WHEN ct IS NULL THEN NULL
                  WHEN nonce IS NULL THEN ct
                  WHEN length(nonce) = 13 THEN nonce || ct
                  ELSE '\\x00'::bytea || nonce || ct END
    $$
    """

    # crdt_head is url-safe base64, no padding, of a 32-byte digest.
    execute """
    CREATE FUNCTION notes_head_digest(h text) RETURNS bytea
    LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path = '' AS $$
      SELECT CASE WHEN h ~ '^[A-Za-z0-9_-]{43}$'
                  THEN decode(translate(h, '-_', '+/') || '=', 'base64') END
    $$
    """

    # link_keys_stamp = path_nonce || Unicode version ("15.1.0"): keys derived
    # for THIS path under that version. As a smallint: major * 100 + minor
    # for the current path, 0 for a stamp left from another path (stale).
    execute """
    CREATE FUNCTION notes_link_keys_v(stamp bytea, path_nonce bytea) RETURNS smallint
    LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path = '' AS $$
      SELECT CASE
        WHEN stamp IS NULL OR path_nonce IS NULL THEN NULL
        WHEN substring(stamp FROM 1 FOR length(path_nonce)) <> path_nonce THEN 0
        ELSE (SELECT (m[1]::int * 100 + m[2]::int)::smallint
              FROM regexp_match(encode(substring(stamp FROM length(path_nonce) + 1), 'escape'),
                                '^([0-9]{1,2})\\.([0-9]{1,2})') AS m)
      END
    $$
    """

    execute """
    CREATE FUNCTION notes_derive_core_keys() RETURNS trigger
    LANGUAGE plpgsql SET search_path = '' AS $$
    BEGIN
      NEW.path_id := public.notes_hmac_id(NEW.path_hmac);
      NEW.folder_id := public.notes_hmac_id(NEW.folder_hmac);
      NEW.basename_id := public.notes_hmac_id(NEW.basename_hmac);
      NEW.path_ci_id := public.notes_hmac_id(NEW.path_ci_hmac);
      NEW.type_id := public.notes_hmac_id(NEW.type_hmac);
      NEW.tag_ids := ARRAY(SELECT public.notes_hmac_id(t)
                           FROM unnest(NEW.tags_hmac) WITH ORDINALITY AS u(t, i)
                           ORDER BY i);
      NEW.is_folder := NEW.kind = 'folder';
      NEW.key_version := CASE WHEN NEW.dek_version BETWEEN 0 AND 32767 THEN NEW.dek_version END;
      NEW.path_len := CASE WHEN NEW.path_length BETWEEN 0 AND 32767 THEN NEW.path_length END;
      NEW.parse_code := CASE NEW.parse_status WHEN 'ok' THEN 0 WHEN 'degraded' THEN 1 END;
      NEW.link_keys_v := public.notes_link_keys_v(NEW.link_keys_stamp, NEW.path_nonce);
      NEW.content_digest := CASE WHEN NEW.content_hash ~ '^([0-9a-f]{2})+$'
                                 THEN decode(NEW.content_hash, 'hex') END;
      RETURN NEW;
    END
    $$
    """

    execute """
    CREATE TRIGGER notes_derive_core_keys
      BEFORE INSERT OR UPDATE OF path_hmac, folder_hmac, basename_hmac, path_ci_hmac,
        type_hmac, tags_hmac, kind, dek_version, path_length, parse_status,
        link_keys_stamp, path_nonce, content_hash
      ON notes FOR EACH ROW EXECUTE FUNCTION notes_derive_core_keys()
    """

    execute """
    CREATE FUNCTION notes_sync_body() RETURNS trigger
    LANGUAGE plpgsql SET search_path = '' AS $$
    BEGIN
      IF NEW.kind IS DISTINCT FROM 'note' THEN
        RETURN NULL;
      END IF;

      IF TG_OP = 'UPDATE' THEN
        IF NEW.content_nonce IS NOT DISTINCT FROM OLD.content_nonce
           AND NEW.crdt_state_nonce IS NOT DISTINCT FROM OLD.crdt_state_nonce
           AND NEW.crdt_head IS NOT DISTINCT FROM OLD.crdt_head
           AND NEW.dek_version IS NOT DISTINCT FROM OLD.dek_version
           AND EXISTS (SELECT 1 FROM public.note_bodies WHERE note_id = NEW.id) THEN
          RETURN NULL;
        END IF;

        UPDATE public.note_bodies SET
          key_version = NEW.dek_version,
          content_ct = CASE WHEN NEW.content_nonce IS DISTINCT FROM OLD.content_nonce
                            THEN public.notes_merge_envelope(NEW.content_nonce, NEW.content_ciphertext)
                            ELSE content_ct END,
          crdt_ct = CASE WHEN NEW.crdt_state_nonce IS DISTINCT FROM OLD.crdt_state_nonce
                         THEN public.notes_merge_envelope(NEW.crdt_state_nonce, NEW.crdt_state_ciphertext)
                         ELSE crdt_ct END,
          crdt_head = CASE WHEN NEW.crdt_head IS DISTINCT FROM OLD.crdt_head
                           THEN public.notes_head_digest(NEW.crdt_head)
                           ELSE crdt_head END
        WHERE note_id = NEW.id;

        IF FOUND THEN
          RETURN NULL;
        END IF;
      END IF;

      INSERT INTO public.note_bodies (note_id, user_id, key_version, content_ct, crdt_ct, crdt_head)
      VALUES (NEW.id, NEW.user_id, NEW.dek_version,
              public.notes_merge_envelope(NEW.content_nonce, NEW.content_ciphertext),
              public.notes_merge_envelope(NEW.crdt_state_nonce, NEW.crdt_state_ciphertext),
              public.notes_head_digest(NEW.crdt_head))
      ON CONFLICT (note_id) DO NOTHING;

      RETURN NULL;
    END
    $$
    """

    execute """
    CREATE TRIGGER notes_sync_body
      AFTER INSERT OR UPDATE OF content_ciphertext, content_nonce, crdt_state_ciphertext,
        crdt_state_nonce, crdt_head, dek_version, kind
      ON notes FOR EACH ROW EXECUTE FUNCTION notes_sync_body()
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS notes_sync_body ON notes"
    execute "DROP FUNCTION IF EXISTS notes_sync_body()"
    execute "DROP TRIGGER IF EXISTS notes_derive_core_keys ON notes"
    execute "DROP FUNCTION IF EXISTS notes_derive_core_keys()"
    execute "DROP FUNCTION IF EXISTS public.notes_link_keys_v(bytea, bytea)"
    execute "DROP FUNCTION IF EXISTS public.notes_head_digest(text)"
    execute "DROP FUNCTION IF EXISTS public.notes_merge_envelope(bytea, bytea)"
    execute "DROP FUNCTION IF EXISTS public.notes_hmac_id(bytea)"
  end
end
