defmodule Engram.Repo.Migrations.CreateChunkStatsExpand do
  use Ecto.Migration

  @moduledoc """
  Per-vault chunk counters (`docs/context/notes-chunks-hyperopt.md` 4.2,
  rank 7), so the point count and BM25 `avgdl` are one row read instead of a
  `count(*)` / `avg` over the user's or vault's chunks:

    * `points`: chunk rows (one per Qdrant point)
    * `len_rows`, `len_sum`: rows with a `token_count` and their sum
      (merged and floor rows carry NULL and stay out of `avgdl`)

  Kept by the `chunks_stats` statement triggers, one per event, from the
  transition tables: every writer (any release, raw SQL, FK cascades) is
  counted with no app change. A vault's row is created by its first chunk
  insert or update after this ships, as an exact `count(*)` of the vault
  at that point (a concurrent first writer that loses the race adds its
  delta instead), so no backfill is needed and no operator step: until a
  vault has a row, readers fall back to the scan they did before. A delete
  never creates a row (a vault delete cascades its chunks here, and its
  row is going too).

  Statements that change no count (an offset or fingerprint update) skip
  the row. One row per vault, fillfactor 70: every chunk write in the
  vault updates it, so HOT room matters more than density. Rows are taken
  in vault order, so two multi-vault statements cannot deadlock on them.
  """

  def up do
    # The FK takes SHARE ROW EXCLUSIVE on vaults, the triggers on chunks.
    execute "SET lock_timeout = '5s'"

    execute """
    CREATE TABLE chunk_stats (
      points bigint NOT NULL,
      len_rows bigint NOT NULL,
      len_sum bigint NOT NULL,
      vault_id uuid PRIMARY KEY REFERENCES vaults(id) ON DELETE CASCADE,
      user_id uuid NOT NULL
    ) WITH (fillfactor = 70)
    """

    execute "ALTER TABLE chunk_stats ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE chunk_stats FORCE ROW LEVEL SECURITY"

    execute """
    CREATE POLICY tenant_isolation_chunk_stats ON chunk_stats
      USING (user_id = (SELECT NULLIF((SELECT current_setting('app.current_tenant', true)), '')::uuid))
      WITH CHECK (user_id = (SELECT NULLIF((SELECT current_setting('app.current_tenant', true)), '')::uuid))
    """

    execute """
    CREATE POLICY maintenance_all ON chunk_stats TO engram_maintenance
      USING (true) WITH CHECK (true)
    """

    execute "GRANT SELECT, INSERT, UPDATE, DELETE ON chunk_stats TO engram_app"

    # Applies one vault's delta; `init` creates a missing row as an exact
    # count (never on a delete: see the moduledoc).
    execute """
    CREATE FUNCTION chunk_stats_apply(v uuid, u uuid, p bigint, lr bigint, ls bigint, init boolean)
    RETURNS void LANGUAGE plpgsql SET search_path = '' AS $$
    BEGIN
      UPDATE public.chunk_stats SET points = points + p, len_rows = len_rows + lr,
        len_sum = len_sum + ls
      WHERE vault_id = v;

      IF NOT FOUND AND init THEN
        BEGIN
          INSERT INTO public.chunk_stats (vault_id, user_id, points, len_rows, len_sum)
          SELECT v, u, count(*), count(c.token_count), coalesce(sum(c.token_count), 0)
          FROM public.chunks c WHERE c.vault_id = v;
        EXCEPTION WHEN unique_violation THEN
          -- A concurrent first writer created it; its count could not see
          -- this statement's rows, so add them.
          UPDATE public.chunk_stats SET points = points + p, len_rows = len_rows + lr,
            len_sum = len_sum + ls
          WHERE vault_id = v;
        END;
      END IF;
    END
    $$
    """

    # Per event, since a transition table exists only for its own event.
    # Zero deltas (an offset or fingerprint update) skip the row.
    for {name, rows, init} <- [
          {"insert",
           "SELECT vault_id, user_id, 1 AS p, (token_count IS NOT NULL)::int AS lr, coalesce(token_count, 0) AS ls FROM new_rows",
           "true"},
          {"update",
           "SELECT vault_id, user_id, 1 AS p, (token_count IS NOT NULL)::int AS lr, coalesce(token_count, 0) AS ls FROM new_rows " <>
             "UNION ALL SELECT vault_id, user_id, -1, -(token_count IS NOT NULL)::int, -coalesce(token_count, 0) FROM old_rows",
           "true"},
          {"delete",
           "SELECT vault_id, user_id, -1 AS p, -(token_count IS NOT NULL)::int AS lr, -coalesce(token_count, 0) AS ls FROM old_rows",
           "false"}
        ] do
      execute """
      CREATE FUNCTION chunks_stats_#{name}() RETURNS trigger
      LANGUAGE plpgsql SET search_path = '' AS $$
      DECLARE
        r record;
      BEGIN
        FOR r IN
          SELECT d.vault_id, min(d.user_id::text)::uuid AS user_id,
                 sum(d.p)::bigint AS p, sum(d.lr)::bigint AS lr, sum(d.ls)::bigint AS ls
          FROM (#{rows}) d
          GROUP BY d.vault_id
          HAVING sum(d.p) <> 0 OR sum(d.lr) <> 0 OR sum(d.ls) <> 0
          ORDER BY d.vault_id
        LOOP
          PERFORM public.chunk_stats_apply(r.vault_id, r.user_id, r.p, r.lr, r.ls, #{init});
        END LOOP;

        RETURN NULL;
      END
      $$
      """
    end

    execute """
    CREATE TRIGGER chunks_stats_insert AFTER INSERT ON chunks
      REFERENCING NEW TABLE AS new_rows
      FOR EACH STATEMENT EXECUTE FUNCTION chunks_stats_insert()
    """

    execute """
    CREATE TRIGGER chunks_stats_update AFTER UPDATE ON chunks
      REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
      FOR EACH STATEMENT EXECUTE FUNCTION chunks_stats_update()
    """

    execute """
    CREATE TRIGGER chunks_stats_delete AFTER DELETE ON chunks
      REFERENCING OLD TABLE AS old_rows
      FOR EACH STATEMENT EXECUTE FUNCTION chunks_stats_delete()
    """

    execute "RESET lock_timeout"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS chunks_stats_delete ON chunks"
    execute "DROP TRIGGER IF EXISTS chunks_stats_update ON chunks"
    execute "DROP TRIGGER IF EXISTS chunks_stats_insert ON chunks"
    execute "DROP FUNCTION IF EXISTS chunks_stats_insert()"
    execute "DROP FUNCTION IF EXISTS chunks_stats_update()"
    execute "DROP FUNCTION IF EXISTS chunks_stats_delete()"

    execute "DROP FUNCTION IF EXISTS chunk_stats_apply(uuid, uuid, bigint, bigint, bigint, boolean)"

    execute "DROP TABLE IF EXISTS chunk_stats"
  end
end
