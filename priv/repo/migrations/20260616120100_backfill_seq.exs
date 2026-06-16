defmodule Engram.Repo.Migrations.BackfillSeq do
  use Ecto.Migration

  @moduledoc """
  Sync change-log backbone, step A backfill. phase/migrate-data.
  Assigns seq to pre-existing notes/attachments per vault in updated_at
  order, then advances each vault.change_seq to its max so future
  next_seq! values stay strictly increasing. Idempotent (seq IS NULL only).

  The `notes`/`attachments` UPDATEs are scoped via the join + `seq IS NULL`
  predicate; they never touch already-stamped rows. The `down` rollback
  intentionally resets every row (full-table `SET seq = NULL` /
  `change_seq = 0`) to fully reverse the backfill — that unguarded update is
  by design for a data-migration rollback, not an oversight. squawk excludes
  `prefer-robust-stmts`, so these full-table UPDATEs are not flagged.
  """

  def up do
    execute("""
    WITH numbered AS (
      SELECT id,
             row_number() OVER (PARTITION BY vault_id ORDER BY updated_at, id) AS rn
      FROM notes
      WHERE seq IS NULL
    )
    UPDATE notes n SET seq = numbered.rn
    FROM numbered WHERE n.id = numbered.id
    """)

    execute("""
    WITH maxn AS (
      SELECT vault_id, COALESCE(max(seq), 0) AS base FROM notes GROUP BY vault_id
    ),
    numbered AS (
      SELECT a.id,
             COALESCE(m.base, 0)
               + row_number() OVER (PARTITION BY a.vault_id ORDER BY a.updated_at, a.id) AS seq
      FROM attachments a
      LEFT JOIN maxn m ON m.vault_id = a.vault_id
      WHERE a.seq IS NULL
    )
    UPDATE attachments a SET seq = numbered.seq
    FROM numbered WHERE a.id = numbered.id
    """)

    execute("""
    UPDATE vaults v SET change_seq = GREATEST(v.change_seq, sub.maxseq)
    FROM (
      SELECT vault_id, max(seq) AS maxseq FROM (
        SELECT vault_id, seq FROM notes
        UNION ALL
        SELECT vault_id, seq FROM attachments
      ) all_rows GROUP BY vault_id
    ) sub
    WHERE v.id = sub.vault_id
    """)
  end

  def down do
    execute("UPDATE notes SET seq = NULL")
    execute("UPDATE attachments SET seq = NULL")
    execute("UPDATE vaults SET change_seq = 0")
  end
end
