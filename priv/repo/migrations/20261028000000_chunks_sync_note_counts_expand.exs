defmodule Engram.Repo.Migrations.ChunksSyncNoteCountsExpand do
  use Ecto.Migration

  @moduledoc """
  Expand: `note_index_state`'s chunk counters (`points`, `len_rows`,
  `len_sum`) are kept by the database on every `chunks` write, so they can
  never drift (#2276).

  Until now only this release's chunk writers kept them, through
  `Indexing.ChunkRows.recount!/2` under the note lock; any other writer (the
  previous release mid-deploy, raw SQL, an FK cascade) left them stale for
  the `NoteIndexState` ledger to find. These triggers cover every writer of
  both releases, with no app change.

  Statement-level, one per event, with transition tables (Postgres allows
  no `UPDATE OF` column list with them, so the UPDATE trigger fires on any
  chunk update; an offset-only update recounts to the same values and
  writes nothing). Each statement recounts the ABSOLUTE counters of the
  distinct notes it touched, one `chunks (note_id, position)` probe each,
  and writes each note's state row once, however many chunk rows moved: a
  50-chunk write is one state update. Absolute, not deltas: the app's
  `recount!` also writes absolutes during the rolling deploy and this
  release, and the two agree instead of fighting. An UPDATE that moves a
  chunk to another note recounts both notes.

  Lock order matches the app's (note, chunks, then the state row): the
  chunk rows are already written when the trigger runs; it then locks the
  state rows in note_id order and counts in a NEW statement, so a
  concurrent writer of the same note that committed while this one waited
  is counted (READ COMMITTED takes a fresh snapshot per statement). A note
  with no state row (a pre-trigger note the ledger has not filled, or one
  whose FK cascade removed it first) updates zero rows, no error; the
  `NoteIndexState` ledger's fill and its windowed recount backstop stay.

  Not SECURITY DEFINER: it runs as the writer, under the writer's tenant
  (`tenant_isolation_note_index_state` admits the note's own row) or on the
  maintenance pool (`maintenance_all`). Reads only `note_id` and
  `token_count` of `chunks`.
  """

  def up do
    # CREATE TRIGGER takes SHARE ROW EXCLUSIVE on chunks: fail fast, the boot
    # migrator retries.
    execute "SET lock_timeout = '5s'"

    execute """
    CREATE FUNCTION chunks_sync_note_counts() RETURNS trigger
    LANGUAGE plpgsql SET search_path = '' AS $$
    DECLARE
      ids uuid[];
    BEGIN
      IF TG_OP = 'INSERT' THEN
        SELECT array_agg(DISTINCT note_id) INTO ids FROM new_chunks;
      ELSIF TG_OP = 'DELETE' THEN
        SELECT array_agg(DISTINCT note_id) INTO ids FROM old_chunks;
      ELSE
        SELECT array_agg(DISTINCT x.note_id) INTO ids
        FROM (SELECT note_id FROM new_chunks UNION SELECT note_id FROM old_chunks) x;
      END IF;

      IF ids IS NULL THEN
        RETURN NULL;
      END IF;

      PERFORM 1 FROM public.note_index_state
        WHERE note_id = ANY(ids) ORDER BY note_id FOR UPDATE;

      UPDATE public.note_index_state s
        SET points = c.p, len_rows = c.lr, len_sum = c.ls
        FROM (SELECT x.id, count(ch.note_id)::int AS p, count(ch.token_count)::int AS lr,
                     coalesce(sum(ch.token_count), 0)::bigint AS ls
              FROM unnest(ids) AS x(id)
              LEFT JOIN public.chunks ch ON ch.note_id = x.id
              GROUP BY x.id) c
        WHERE s.note_id = c.id
          AND (s.points, s.len_rows, s.len_sum) IS DISTINCT FROM (c.p, c.lr, c.ls);

      RETURN NULL;
    END
    $$
    """

    execute """
    CREATE TRIGGER chunks_sync_note_counts_insert
      AFTER INSERT ON chunks REFERENCING NEW TABLE AS new_chunks
      FOR EACH STATEMENT EXECUTE FUNCTION chunks_sync_note_counts()
    """

    execute """
    CREATE TRIGGER chunks_sync_note_counts_update
      AFTER UPDATE ON chunks REFERENCING OLD TABLE AS old_chunks NEW TABLE AS new_chunks
      FOR EACH STATEMENT EXECUTE FUNCTION chunks_sync_note_counts()
    """

    execute """
    CREATE TRIGGER chunks_sync_note_counts_delete
      AFTER DELETE ON chunks REFERENCING OLD TABLE AS old_chunks
      FOR EACH STATEMENT EXECUTE FUNCTION chunks_sync_note_counts()
    """

    execute "RESET lock_timeout"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS chunks_sync_note_counts_insert ON chunks"
    execute "DROP TRIGGER IF EXISTS chunks_sync_note_counts_update ON chunks"
    execute "DROP TRIGGER IF EXISTS chunks_sync_note_counts_delete ON chunks"
    execute "DROP FUNCTION IF EXISTS chunks_sync_note_counts()"
  end
end
