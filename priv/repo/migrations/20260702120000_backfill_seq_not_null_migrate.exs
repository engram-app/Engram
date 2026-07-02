defmodule Engram.Repo.Migrations.BackfillSeqNotNullMigrate do
  use Ecto.Migration

  # phase/migrate-data — backfill NULL seq rows, then harden with NOT NULL.
  #
  # The seq change feed filters `seq IS NOT NULL`, so a NULL-seq row silently
  # never syncs. Every current write path stamps seq app-side, but nothing at
  # the DB level enforced it, and the backfill the 20260616120000 moduledoc
  # promised (20260616120100) never shipped. Backfill any stragglers per
  # vault (ordered by updated_at so backfilled history replays in edit
  # order), advance the vault counter past them, then add validated NOT NULL
  # constraints (PG18 named-constraint pattern — no ACCESS EXCLUSIVE scan;
  # see AGENTS.md "PG18-era cheap patterns").
  #
  # notes/attachments/vaults carry FORCE ROW LEVEL SECURITY and the migrator
  # has no tenant context — without the NO FORCE dance this DML silently
  # touches 0 rows on prod (see docs/context/migrations-force-rls-data-dml.md).
  def up do
    execute("ALTER TABLE notes NO FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE attachments NO FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE vaults NO FORCE ROW LEVEL SECURITY")

    execute(backfill_sql("notes"))
    execute(backfill_sql("attachments"))

    execute("""
    DO $$
    DECLARE remaining bigint;
    BEGIN
      SELECT COUNT(*) INTO remaining FROM notes WHERE seq IS NULL;
      IF remaining > 0 THEN
        RAISE EXCEPTION 'seq backfill incomplete: % notes rows still NULL', remaining;
      END IF;
      SELECT COUNT(*) INTO remaining FROM attachments WHERE seq IS NULL;
      IF remaining > 0 THEN
        RAISE EXCEPTION 'seq backfill incomplete: % attachments rows still NULL', remaining;
      END IF;
    END $$;
    """)

    execute("ALTER TABLE notes FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE attachments FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE vaults FORCE ROW LEVEL SECURITY")

    execute("ALTER TABLE notes ADD CONSTRAINT notes_seq_not_null NOT NULL seq NOT VALID")
    execute("ALTER TABLE notes VALIDATE CONSTRAINT notes_seq_not_null")

    execute(
      "ALTER TABLE attachments ADD CONSTRAINT attachments_seq_not_null NOT NULL seq NOT VALID"
    )

    execute("ALTER TABLE attachments VALIDATE CONSTRAINT attachments_seq_not_null")
  end

  def down do
    execute("ALTER TABLE notes DROP CONSTRAINT notes_seq_not_null")
    execute("ALTER TABLE attachments DROP CONSTRAINT attachments_seq_not_null")
    # Backfilled seq values stay — they are valid feed entries, not damage.
  end

  # Assign each NULL-seq row the next seqs after the vault's current counter
  # (ordered by updated_at, id within the vault), then advance the counter
  # past them so live writes can't collide. Both UPDATEs share the `nulls`
  # CTE snapshot, so the counts match by construction.
  defp backfill_sql(table) do
    """
    WITH nulls AS (
      SELECT id, vault_id,
             row_number() OVER (PARTITION BY vault_id ORDER BY updated_at, id) AS rn
      FROM #{table}
      WHERE seq IS NULL
    ),
    bumped AS (
      UPDATE #{table} t
      SET seq = v.change_seq + nulls.rn
      FROM nulls
      JOIN vaults v ON v.id = nulls.vault_id
      WHERE t.id = nulls.id
      RETURNING t.id
    )
    UPDATE vaults v
    SET change_seq = v.change_seq + c.cnt
    FROM (SELECT vault_id, count(*) AS cnt FROM nulls GROUP BY vault_id) c
    WHERE v.id = c.vault_id
    """
  end
end
