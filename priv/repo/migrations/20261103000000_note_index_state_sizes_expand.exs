defmodule Engram.Repo.Migrations.NoteIndexStateSizesExpand do
  use Ecto.Migration

  @moduledoc """
  Narrow, trigger-kept sizes and liveness so `CrdtBloatSweep` (and the daily
  snapshot, PostHog sync and budget sweep) stop aggregating every wide `notes`
  row (prod 2026-11-03: the bloat aggregate took 14,982 ms against the 15 s
  query timeout and swapped the database), WITHOUT adding a row version to
  any save:

    * `note_bodies.content_bytes` / `state_bytes`: the stored payload of the
      merged body columns (`octet_length - 13` nonce field `- 16` tag,
      `note_body_payload_bytes/1`; each NULL when its ciphertext is NULL, so a body with
      no content counts 0 bytes as before), set by the BEFORE trigger `note_bodies_sizes` on the row being
      written: no extra row. `octet_length` reads the varlena header, never
      de-TOASTs. From `note_bodies`, which the R8 contract keeps.
      Follow-up: once R8 N lands (`NoteBody.sync!/3`, #2400), write the sizes
      in that statement and drop this trigger.
    * `note_index_state.note_live` (`deleted_at IS NULL`): folded into the
      EXISTING `note_index_state_sync` upsert (the same `IS DISTINCT FROM`
      guard, so an unchanged row is never written), whose trigger now also
      fires on `deleted_at`, which changes on a soft delete or restore only.

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
      ADD COLUMN IF NOT EXISTS state_bytes integer
    """

    execute "ALTER TABLE note_index_state ADD COLUMN IF NOT EXISTS note_live boolean"

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
      RETURN NEW;
    END
    $$
    """

    execute """
    CREATE TRIGGER note_bodies_sizes
      BEFORE INSERT OR UPDATE OF content_ct, crdt_ct ON note_bodies
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
        dense_indexed_hash, embed_started_hash, payload_hash, note_live)
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
        n.deleted_at IS NULL)
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
    execute "ALTER TABLE note_index_state DROP COLUMN IF EXISTS note_live"

    execute """
    ALTER TABLE note_bodies
      DROP COLUMN IF EXISTS content_bytes, DROP COLUMN IF EXISTS state_bytes
    """

    execute "RESET lock_timeout"
  end
end
