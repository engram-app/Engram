defmodule Engram.Repo.Migrations.CreateNoteIndexStateExpand do
  use Ecto.Migration

  @moduledoc """
  Expand step of the embed-bookkeeping split
  (`docs/context/notes-chunks-hyperopt.md` 2.3, rank 11): everything the
  indexer derives about a note, in its own 1:1 table, so the embed
  pipeline's 3-5 stamps per run stop rewriting the wide `notes` row once
  readers switch (next release) and the old columns are dropped (contract).

  Columns keep the `notes` names, so the read switch is a source swap.
  Narrowed where the cast is total: the version stamps and the crash count
  to int2 and `chunk_count` to int4, clamped (no real value comes near; a
  CASE, not LEAST/GREATEST, which turn NULL into the bound).
  `embed_hash`, `embed_started_hash` stay: `ReconcileEmbeddings`, the
  crash guard and `EmbedNote` all read them, so dropping them is a reader
  change, not an expand.

  Dual write is in the database, as wave 3 does for `note_bodies`
  (20261021110200): the `notes_sync_index_state` trigger covers every
  writer, this release's code, the previous release's nodes during a
  rolling deploy, raw SQL and the qdrant lane's NULL-clears, with no app
  change. It fires only on a write that lists one of the mirrored columns
  (`UPDATE OF`), and its upsert skips an identical row, so a content-only
  checkpoint never touches this table. Rows written before the trigger are
  filled by the `NoteIndexState` data migration through the same function.

  It also holds the note's chunk counters (`points`, `len_rows`, `len_sum`:
  rows, rows with a `token_count`, their sum), written by this release's
  chunk writers in the same transaction as the chunk rows, under the note's
  own lock (`Indexing.ChunkRows.recount!/1`): per note, so no shared row.
  Every writer locks note, chunks, then this row (`Indexing.ChunkRows`,
  "Lock order"). The trigger never touches them. Vault and user totals
  are SUMs over the vault (`note_index_state_vault`, a later migration), read
  once the `NoteIndexState` ledger has counted every note; it also re-counts
  daily, healing what a previous-release writer left behind.

  The embed columns are not read yet (rollback-safe: the previous release
  ignores the table and the trigger keeps it current while that release
  writes notes).

  fillfactor 80: every embed run updates the row, and the slack keeps those
  updates HOT.
  """

  def up do
    # The FK and the trigger take SHARE ROW EXCLUSIVE on notes: fail fast,
    # the boot migrator retries.
    execute "SET lock_timeout = '5s'"

    # squawk-ignore: prefer-bigint-over-smallint, prefer-bigint-over-int
    # Bounded stamps (versions, crash count, a note's chunk count), clamped on write.
    execute """
    CREATE TABLE note_index_state (
      embed_retry_after timestamptz,
      embed_started_at timestamptz,
      rebuild_paid_at timestamptz,
      embed_budget_parked_at timestamptz,
      embed_budget_need bigint,
      embed_budget_next bigint,
      len_sum bigint NOT NULL DEFAULT 0,
      note_id uuid PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
      user_id uuid NOT NULL,
      vault_id uuid NOT NULL,
      points integer NOT NULL DEFAULT 0,
      len_rows integer NOT NULL DEFAULT 0,
      chunk_count integer,
      chunker_version smallint,
      keyword_version smallint,
      key_alias_version smallint,
      embed_crashes smallint,
      embed_budget_parked boolean,
      index_tier text,
      embed_model text,
      embed_started_by text,
      embed_hash text,
      dense_indexed_hash text,
      embed_started_hash text,
      payload_hash bytea
    ) WITH (fillfactor = 80)
    """

    execute "ALTER TABLE note_index_state ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE note_index_state FORCE ROW LEVEL SECURITY"

    execute """
    CREATE POLICY tenant_isolation_note_index_state ON note_index_state
      USING (user_id = (SELECT NULLIF((SELECT current_setting('app.current_tenant', true)), '')::uuid))
      WITH CHECK (user_id = (SELECT NULLIF((SELECT current_setting('app.current_tenant', true)), '')::uuid))
    """

    execute """
    CREATE POLICY maintenance_all ON note_index_state TO engram_maintenance
      USING (true) WITH CHECK (true)
    """

    execute "GRANT SELECT, INSERT, UPDATE, DELETE ON note_index_state TO engram_app"

    # One mapping for the trigger and the backfill. `overwrite` false is the
    # backfill: its row snapshot may be older than a concurrent writer's, so
    # it only fills a missing row and never replaces one.
    execute """
    CREATE FUNCTION note_index_state_sync(n public.notes, overwrite boolean) RETURNS void
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

    execute """
    CREATE FUNCTION notes_sync_index_state() RETURNS trigger
    LANGUAGE plpgsql SET search_path = '' AS $$
    BEGIN
      PERFORM public.note_index_state_sync(NEW, true);
      RETURN NULL;
    END
    $$
    """

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

    execute "RESET lock_timeout"
  end

  def down do
    # The ledger must not outlive what it vouches for.
    execute "DELETE FROM data_migrations WHERE name = 'note_index_state'"
    execute "DROP TRIGGER IF EXISTS notes_sync_index_state ON notes"
    execute "DROP FUNCTION IF EXISTS notes_sync_index_state()"
    execute "DROP FUNCTION IF EXISTS note_index_state_sync(public.notes, boolean)"
    execute "DROP TABLE IF EXISTS note_index_state"
  end
end
