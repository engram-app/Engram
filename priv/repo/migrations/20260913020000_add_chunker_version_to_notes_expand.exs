defmodule Engram.Repo.Migrations.AddChunkerVersionToNotesExpand do
  use Ecto.Migration

  @moduledoc """
  #1620 — records which chunker built a note's index rows.

  `EmbedNote` skips a note when `embed_hash == content_hash`, and nothing
  recorded which chunker produced the chunks. So every chunker fix (#1591,
  #1600, #1605) reached only notes that someone happened to edit afterwards.
  Prod evidence: sections spanning 2.5MB in three chunk rows, left by the
  pre-#1591 splitter, whose dense vector covers only Voyage's truncated prefix
  and whose token_count inflates the vault's BM25 `avgdl` for every OTHER
  chunk in that vault.

  Deliberately NOT backfilled. NULL is the signal — "indexed by a chunker that
  predates this stamp" — and that is exactly the set that needs rebuilding.
  Writing a value here would erase the only evidence of which rows are stale.
  That also keeps this migration free of tenant-table DML, so it needs none of
  the `NO FORCE ROW LEVEL SECURITY` dance (see
  `docs/context/migrations-force-rls-data-dml.md`).

  Re-indexing is NOT automatic: `ReconcileEmbeddings` does not select on this
  column, so shipping the migration cannot trigger a corpus-wide re-embed.
  An operator drives the backfill per vault via `ReindexKeyword`, which does
  real work on the first run after a version bump and is a no-op afterwards.
  """

  def up do
    alter table(:notes) do
      # `:bigint`, not `:integer` — squawk's prefer-bigint-over-int gate fails
      # the build on a 32-bit int column. A chunker version will never approach
      # 2^31, but 4 extra bytes on a nullable column is cheaper than an
      # exception, and the Ecto field stays `:integer` (it reads int8 fine).
      add :chunker_version, :bigint
    end
  end

  def down do
    alter table(:notes) do
      remove :chunker_version
    end
  end
end
