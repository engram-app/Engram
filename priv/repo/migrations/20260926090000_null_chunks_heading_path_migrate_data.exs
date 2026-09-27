defmodule Engram.Repo.Migrations.NullChunksHeadingPathMigrateData do
  use Ecto.Migration

  # `chunks.heading_path` held a PLAINTEXT copy of "Title > H1 > H2" — note
  # titles and headings — next to the encrypted copy in the Qdrant payload.
  # Nothing reads the column (search reads the Qdrant copy), and indexing stops
  # writing it in the same release. This clears what is already stored; the
  # column is dropped by a phase/contract migration in the following release.
  #
  # `chunks` is a FORCE RLS tenant table, so the UPDATE must run unforced or it
  # touches zero rows on prod (docs/context/migrations-force-rls-data-dml.md).
  # ~30k rows on prod: one statement under the brief ACCESS EXCLUSIVE lock.
  def up do
    execute("ALTER TABLE chunks NO FORCE ROW LEVEL SECURITY")
    execute("UPDATE chunks SET heading_path = NULL WHERE heading_path IS NOT NULL")

    execute("""
    DO $$
    DECLARE remaining bigint;
    BEGIN
      SELECT count(*) INTO remaining FROM chunks WHERE heading_path IS NOT NULL;
      IF remaining > 0 THEN
        RAISE EXCEPTION 'chunks.heading_path still set on % rows', remaining;
      END IF;
    END $$;
    """)

    execute("ALTER TABLE chunks FORCE ROW LEVEL SECURITY")
  end

  # Irreversible: the plaintext is gone by design, and nothing reads it.
  def down, do: :ok
end
