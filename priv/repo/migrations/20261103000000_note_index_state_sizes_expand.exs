defmodule Engram.Repo.Migrations.NoteIndexStateSizesExpand do
  use Ecto.Migration

  @moduledoc """
  Narrow sizes, liveness and an envelope-drift flag, WITHOUT adding a row
  version to any save and without costing `note_bodies` its heap-only (HOT)
  updates (`notes_hot_append_test`, row versions measured per save):

    * `note_bodies.content_bytes` / `state_bytes` / `envelope_legacy`, set on
      the row being written by the BEFORE trigger `note_bodies_sizes` (no
      extra row). Sizes are the stored payload (`octet_length - 13` nonce
      field `- 16` tag, `note_body_payload_bytes/1`), NULL when the
      ciphertext is NULL; `octet_length` reads the varlena header, never
      de-TOASTs. `envelope_legacy` is the format-0 test the drift drain's
      partial index needs: an index on the ciphertext expression would make
      every body write non-HOT, a flag that stays false does not. None of
      these columns is in an index except the flag. From `note_bodies`, which
      the R8 contract keeps. Follow-up: once R8 N lands (`NoteBody.sync!/3`,
      #2400), write them in that statement and drop this trigger.
    * `note_index_state.note_live` (`deleted_at IS NULL`): folded into the
      EXISTING `note_index_state_sync` upsert (same `IS DISTINCT FROM`
      guard), whose trigger now also fires on `deleted_at`.
    * `note_index_state.content_bytes` / `state_bytes` / `has_state`: a narrow
      copy of the body sizes for the hourly `CrdtBloatSweep` percentiles:
      seeded by the state row's own INSERT when a note is created, then
      copied by the sweep for the notes written since its last run (one HOT
      row version per written note per hour, off the save path), never by a
      save. Readers see edits up to an hour late.

  Additive and nullable: the previous release ignores the columns, and
  `NoteSizes` (data migration) fills rows written before the triggers.
  """

  def up do
    execute "SET lock_timeout = '5s'"

    # squawk-ignore: prefer-bigint-over-int
    # Stored byte sizes of one note, far below 2 GB.
    execute """
    -- squawk-ignore prefer-bigint-over-int
    ALTER TABLE note_bodies
      ADD COLUMN IF NOT EXISTS content_bytes integer,
      ADD COLUMN IF NOT EXISTS state_bytes integer,
      ADD COLUMN IF NOT EXISTS envelope_legacy boolean
    """

    execute """
    -- squawk-ignore prefer-bigint-over-int
    ALTER TABLE note_index_state
      ADD COLUMN IF NOT EXISTS note_live boolean,
      ADD COLUMN IF NOT EXISTS content_bytes integer,
      ADD COLUMN IF NOT EXISTS state_bytes integer,
      ADD COLUMN IF NOT EXISTS has_state boolean
    """

    execute """
    CREATE FUNCTION note_body_payload_bytes(ct bytea) RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path = '' AS $$
      SELECT greatest(octet_length(ct) - 29, 0)
    $$
    """

    execute """
    CREATE FUNCTION note_bodies_sizes() RETURNS trigger
    LANGUAGE plpgsql SET search_path = '' AS $$
    BEGIN
      NEW.content_bytes := CASE WHEN NEW.content_ct IS NULL THEN NULL
                                ELSE public.note_body_payload_bytes(NEW.content_ct) END;
      NEW.state_bytes := CASE WHEN NEW.crdt_ct IS NULL THEN NULL
                              ELSE public.note_body_payload_bytes(NEW.crdt_ct) END;
      -- Format 0: the merged nonce field starts with a 0 byte. The content
      -- test needs an AAD-bound row (`Crypto.row_version_aad_bound/0`).
      NEW.envelope_legacy :=
        coalesce(substring(NEW.content_ct FROM 1 FOR 1) = '\\x00'::bytea
                 AND octet_length(NEW.content_ct) > 29 AND NEW.key_version >= 2, false)
        OR coalesce(substring(NEW.crdt_ct FROM 1 FOR 1) = '\\x00'::bytea
                    AND octet_length(NEW.crdt_ct) > 29, false);
      RETURN NEW;
    END
    $$
    """

    execute """
    CREATE TRIGGER note_bodies_sizes
      BEFORE INSERT OR UPDATE OF content_ct, crdt_ct, key_version ON note_bodies
      FOR EACH ROW EXECUTE FUNCTION note_bodies_sizes()
    """

    execute """
    CREATE OR REPLACE FUNCTION note_index_state_sync(n public.notes, overwrite boolean) RETURNS void
    LANGUAGE plpgsql SET search_path = '' AS $$
    BEGIN
      INSERT INTO public.note_index_state AS s (
        note_id, user_id, vault_id, embed_retry_after, embed_started_at, rebuild_paid_at,
        embed_budget_parked_at, embed_budget_need, embed_budget_next, chunk_count,
        chunker_version, keyword_version, key_alias_version, embed_crashes,
        embed_budget_parked, index_tier, embed_model, embed_started_by, embed_hash,
        dense_indexed_hash, embed_started_hash, payload_hash, note_live,
        content_bytes, state_bytes, has_state)
      VALUES (
        n.id, n.user_id, n.vault_id, n.embed_retry_after, n.embed_started_at, n.rebuild_paid_at,
        n.embed_budget_parked_at, n.embed_budget_need, n.embed_budget_next,
        (CASE WHEN n.chunk_count < -2147483648 THEN -2147483648 WHEN n.chunk_count > 2147483647 THEN 2147483647 ELSE n.chunk_count END)::integer,
        (CASE WHEN n.chunker_version < -32768 THEN -32768 WHEN n.chunker_version > 32767 THEN 32767 ELSE n.chunker_version END)::smallint,
        (CASE WHEN n.keyword_version < -32768 THEN -32768 WHEN n.keyword_version > 32767 THEN 32767 ELSE n.keyword_version END)::smallint,
        (CASE WHEN n.key_alias_version < -32768 THEN -32768 WHEN n.key_alias_version > 32767 THEN 32767 ELSE n.key_alias_version END)::smallint,
        (CASE WHEN n.embed_crashes < -32768 THEN -32768 WHEN n.embed_crashes > 32767 THEN 32767 ELSE n.embed_crashes END)::smallint,
        n.embed_budget_parked, n.index_tier, n.embed_model, n.embed_started_by,
        n.embed_hash, n.dense_indexed_hash, n.embed_started_hash, n.payload_hash,
        n.deleted_at IS NULL,
        -- Seeded at creation only (not in the DO UPDATE list): the body row
        -- exists, `notes_sync_body` runs first. Edits are copied hourly by
        -- `CrdtBloatSweep`.
        (SELECT b.content_bytes FROM public.note_bodies b WHERE b.note_id = n.id),
        (SELECT b.state_bytes FROM public.note_bodies b WHERE b.note_id = n.id),
        (SELECT b.state_bytes IS NOT NULL FROM public.note_bodies b WHERE b.note_id = n.id))
      ON CONFLICT (note_id) DO UPDATE SET
        user_id = EXCLUDED.user_id,
        vault_id = EXCLUDED.vault_id,
        embed_retry_after = EXCLUDED.embed_retry_after,
        embed_started_at = EXCLUDED.embed_started_at,
        rebuild_paid_at = EXCLUDED.rebuild_paid_at,
        embed_budget_parked_at = EXCLUDED.embed_budget_parked_at,
        embed_budget_need = EXCLUDED.embed_budget_need,
        embed_budget_next = EXCLUDED.embed_budget_next,
        chunk_count = EXCLUDED.chunk_count,
        chunker_version = EXCLUDED.chunker_version,
        keyword_version = EXCLUDED.keyword_version,
        key_alias_version = EXCLUDED.key_alias_version,
        embed_crashes = EXCLUDED.embed_crashes,
        embed_budget_parked = EXCLUDED.embed_budget_parked,
        index_tier = EXCLUDED.index_tier,
        embed_model = EXCLUDED.embed_model,
        embed_started_by = EXCLUDED.embed_started_by,
        embed_hash = EXCLUDED.embed_hash,
        dense_indexed_hash = EXCLUDED.dense_indexed_hash,
        embed_started_hash = EXCLUDED.embed_started_hash,
        payload_hash = EXCLUDED.payload_hash,
        note_live = EXCLUDED.note_live
      WHERE overwrite AND (
        s.user_id, s.vault_id, s.embed_retry_after, s.embed_started_at, s.rebuild_paid_at,
        s.embed_budget_parked_at, s.embed_budget_need, s.embed_budget_next, s.chunk_count,
        s.chunker_version, s.keyword_version, s.key_alias_version, s.embed_crashes,
        s.embed_budget_parked, s.index_tier, s.embed_model, s.embed_started_by, s.embed_hash,
        s.dense_indexed_hash, s.embed_started_hash, s.payload_hash, s.note_live
      ) IS DISTINCT FROM (
        EXCLUDED.user_id, EXCLUDED.vault_id, EXCLUDED.embed_retry_after, EXCLUDED.embed_started_at,
        EXCLUDED.rebuild_paid_at, EXCLUDED.embed_budget_parked_at, EXCLUDED.embed_budget_need,
        EXCLUDED.embed_budget_next, EXCLUDED.chunk_count, EXCLUDED.chunker_version,
        EXCLUDED.keyword_version, EXCLUDED.key_alias_version, EXCLUDED.embed_crashes,
        EXCLUDED.embed_budget_parked, EXCLUDED.index_tier, EXCLUDED.embed_model,
        EXCLUDED.embed_started_by, EXCLUDED.embed_hash, EXCLUDED.dense_indexed_hash,
        EXCLUDED.embed_started_hash, EXCLUDED.payload_hash, EXCLUDED.note_live
      );
    END
    $$
    """

    execute "DROP TRIGGER IF EXISTS notes_sync_index_state ON notes"

    execute """
    CREATE TRIGGER notes_sync_index_state
      AFTER INSERT OR UPDATE OF embed_retry_after, embed_started_at, rebuild_paid_at,
        embed_budget_parked_at, embed_budget_need, embed_budget_next, chunk_count,
        chunker_version, keyword_version, key_alias_version, embed_crashes,
        embed_budget_parked, index_tier, embed_model, embed_started_by, embed_hash,
        dense_indexed_hash, embed_started_hash, payload_hash, kind, user_id, vault_id, deleted_at
      ON notes FOR EACH ROW WHEN (NEW.kind = 'note')
      EXECUTE FUNCTION notes_sync_index_state()
    """

    execute "RESET lock_timeout"
  end

  def down do
    execute "SET lock_timeout = '5s'"
    execute "DELETE FROM data_migrations WHERE name = 'note_sizes'"

    execute """
    CREATE OR REPLACE FUNCTION note_index_state_sync(n public.notes, overwrite boolean) RETURNS void
    LANGUAGE plpgsql SET search_path = '' AS $$
    BEGIN
      INSERT INTO public.note_index_state AS s (
        note_id, user_id, vault_id, embed_retry_after, embed_started_at, rebuild_paid_at,
        embed_budget_parked_at, embed_budget_need, embed_budget_next, chunk_count,
        chunker_version, keyword_version, key_alias_version, embed_crashes,
        embed_budget_parked, index_tier, embed_model, embed_started_by, embed_hash,
        dense_indexed_hash, embed_started_hash, payload_hash)
      VALUES (
        n.id, n.user_id, n.vault_id, n.embed_retry_after, n.embed_started_at, n.rebuild_paid_at,
        n.embed_budget_parked_at, n.embed_budget_need, n.embed_budget_next,
        (CASE WHEN n.chunk_count < -2147483648 THEN -2147483648 WHEN n.chunk_count > 2147483647 THEN 2147483647 ELSE n.chunk_count END)::integer,
        (CASE WHEN n.chunker_version < -32768 THEN -32768 WHEN n.chunker_version > 32767 THEN 32767 ELSE n.chunker_version END)::smallint,
        (CASE WHEN n.keyword_version < -32768 THEN -32768 WHEN n.keyword_version > 32767 THEN 32767 ELSE n.keyword_version END)::smallint,
        (CASE WHEN n.key_alias_version < -32768 THEN -32768 WHEN n.key_alias_version > 32767 THEN 32767 ELSE n.key_alias_version END)::smallint,
        (CASE WHEN n.embed_crashes < -32768 THEN -32768 WHEN n.embed_crashes > 32767 THEN 32767 ELSE n.embed_crashes END)::smallint,
        n.embed_budget_parked, n.index_tier, n.embed_model, n.embed_started_by,
        n.embed_hash, n.dense_indexed_hash, n.embed_started_hash, n.payload_hash)
      ON CONFLICT (note_id) DO UPDATE SET
        user_id = EXCLUDED.user_id,
        vault_id = EXCLUDED.vault_id,
        embed_retry_after = EXCLUDED.embed_retry_after,
        embed_started_at = EXCLUDED.embed_started_at,
        rebuild_paid_at = EXCLUDED.rebuild_paid_at,
        embed_budget_parked_at = EXCLUDED.embed_budget_parked_at,
        embed_budget_need = EXCLUDED.embed_budget_need,
        embed_budget_next = EXCLUDED.embed_budget_next,
        chunk_count = EXCLUDED.chunk_count,
        chunker_version = EXCLUDED.chunker_version,
        keyword_version = EXCLUDED.keyword_version,
        key_alias_version = EXCLUDED.key_alias_version,
        embed_crashes = EXCLUDED.embed_crashes,
        embed_budget_parked = EXCLUDED.embed_budget_parked,
        index_tier = EXCLUDED.index_tier,
        embed_model = EXCLUDED.embed_model,
        embed_started_by = EXCLUDED.embed_started_by,
        embed_hash = EXCLUDED.embed_hash,
        dense_indexed_hash = EXCLUDED.dense_indexed_hash,
        embed_started_hash = EXCLUDED.embed_started_hash,
        payload_hash = EXCLUDED.payload_hash
      WHERE overwrite AND (
        s.user_id, s.vault_id, s.embed_retry_after, s.embed_started_at, s.rebuild_paid_at,
        s.embed_budget_parked_at, s.embed_budget_need, s.embed_budget_next, s.chunk_count,
        s.chunker_version, s.keyword_version, s.key_alias_version, s.embed_crashes,
        s.embed_budget_parked, s.index_tier, s.embed_model, s.embed_started_by, s.embed_hash,
        s.dense_indexed_hash, s.embed_started_hash, s.payload_hash
      ) IS DISTINCT FROM (
        EXCLUDED.user_id, EXCLUDED.vault_id, EXCLUDED.embed_retry_after, EXCLUDED.embed_started_at,
        EXCLUDED.rebuild_paid_at, EXCLUDED.embed_budget_parked_at, EXCLUDED.embed_budget_need,
        EXCLUDED.embed_budget_next, EXCLUDED.chunk_count, EXCLUDED.chunker_version,
        EXCLUDED.keyword_version, EXCLUDED.key_alias_version, EXCLUDED.embed_crashes,
        EXCLUDED.embed_budget_parked, EXCLUDED.index_tier, EXCLUDED.embed_model,
        EXCLUDED.embed_started_by, EXCLUDED.embed_hash, EXCLUDED.dense_indexed_hash,
        EXCLUDED.embed_started_hash, EXCLUDED.payload_hash
      );
    END
    $$
    """

    execute "DROP TRIGGER IF EXISTS notes_sync_index_state ON notes"

    execute """
    CREATE TRIGGER notes_sync_index_state
      AFTER INSERT OR UPDATE OF embed_retry_after, embed_started_at, rebuild_paid_at,
        embed_budget_parked_at, embed_budget_need, embed_budget_next, chunk_count,
        chunker_version, keyword_version, key_alias_version, embed_crashes,
        embed_budget_parked, index_tier, embed_model, embed_started_by, embed_hash,
        dense_indexed_hash, embed_started_hash, payload_hash, kind, user_id, vault_id
      ON notes FOR EACH ROW WHEN (NEW.kind = 'note')
      EXECUTE FUNCTION notes_sync_index_state()
    """

    execute "DROP TRIGGER IF EXISTS note_bodies_sizes ON note_bodies"
    execute "DROP FUNCTION IF EXISTS note_bodies_sizes()"
    execute "DROP FUNCTION IF EXISTS note_body_payload_bytes(bytea)"

    execute """
    ALTER TABLE note_index_state
      DROP COLUMN IF EXISTS note_live, DROP COLUMN IF EXISTS content_bytes,
      DROP COLUMN IF EXISTS state_bytes, DROP COLUMN IF EXISTS has_state
    """

    execute """
    ALTER TABLE note_bodies
      DROP COLUMN IF EXISTS content_bytes, DROP COLUMN IF EXISTS state_bytes,
      DROP COLUMN IF EXISTS envelope_legacy
    """

    execute "RESET lock_timeout"
  end
end
