defmodule Engram.Repo.Migrations.NullStaleIndexHashesMigrateData do
  use Ecto.Migration

  # #1610 backfill. Soft delete used to keep `embed_hash` and
  # `dense_indexed_hash` while `DeleteNoteIndex` dropped the note's chunks and
  # points, so a resurrected note matched its `content_hash` and was never
  # re-embedded. The code fix covers deletes from now on. This clears the rows
  # it cannot reach:
  #
  #   1. Tombstones still carrying the hashes (a future resurrect would break).
  #   2. Live notes already resurrected: stamped, but with no chunks at all.
  #
  # (2) also matches over-cap and empty notes, which legitimately have no
  # chunks. That is safe: `Indexing.index_note/2` returns before calling the
  # embedder for both, and `EmbedNote` restamps them. The cost is one job each.
  #
  # Both tables are FORCE RLS, so they run unforced or the UPDATEs touch zero
  # rows on prod (docs/context/migrations-force-rls-data-dml.md). `chunks` MUST
  # be unforced too: if the NOT EXISTS read saw no chunks, (2) would null every
  # live note and re-embed the whole corpus. The pre-check below refuses that.
  @statements [
    "ALTER TABLE notes NO FORCE ROW LEVEL SECURITY",
    "ALTER TABLE chunks NO FORCE ROW LEVEL SECURITY",
    """
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM chunks)
         AND EXISTS (SELECT 1 FROM notes WHERE deleted_at IS NULL AND embed_hash IS NOT NULL) THEN
        RAISE EXCEPTION 'chunks reads empty while notes are stamped: refusing a corpus-wide re-embed';
      END IF;
    END $$;
    """,
    """
    UPDATE notes SET embed_hash = NULL, dense_indexed_hash = NULL
    WHERE deleted_at IS NOT NULL
      AND (embed_hash IS NOT NULL OR dense_indexed_hash IS NOT NULL)
    """,
    """
    UPDATE notes SET embed_hash = NULL, dense_indexed_hash = NULL
    WHERE deleted_at IS NULL
      AND kind = 'note'
      AND (embed_hash IS NOT NULL OR dense_indexed_hash IS NOT NULL)
      AND NOT EXISTS (SELECT 1 FROM chunks c WHERE c.note_id = notes.id)
    """,
    """
    DO $$
    DECLARE remaining bigint;
    BEGIN
      SELECT count(*) INTO remaining FROM notes n
      WHERE (n.embed_hash IS NOT NULL OR n.dense_indexed_hash IS NOT NULL)
        AND (n.deleted_at IS NOT NULL
             OR (n.kind = 'note' AND NOT EXISTS (SELECT 1 FROM chunks c WHERE c.note_id = n.id)));
      IF remaining > 0 THEN
        RAISE EXCEPTION 'stale index hashes still set on % notes', remaining;
      END IF;
    END $$;
    """,
    "ALTER TABLE chunks FORCE ROW LEVEL SECURITY",
    "ALTER TABLE notes FORCE ROW LEVEL SECURITY"
  ]

  # Exposed for the test, which runs the same SQL inside the sandbox.
  def statements, do: @statements

  def up, do: Enum.each(@statements, &execute/1)

  # Irreversible and harmless to leave applied: a nulled hash only re-queues
  # the note for indexing.
  def down, do: :ok
end
