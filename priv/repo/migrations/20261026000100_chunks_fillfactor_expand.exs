defmodule Engram.Repo.Migrations.ChunksFillfactorExpand do
  use Ecto.Migration

  # Chunk rows are now updated in place when a re-index moves them
  # (`Indexing.write_chunk_rows/2`), instead of deleted and reinserted: an
  # edit shifts every later section's offsets, and those updates touch no
  # indexed column, so they are HOT when the page has room. At fillfactor 100
  # (prod: 7.6% HOT on 2026-10-24) it rarely does. Applies to pages written
  # from now on; chunk rows churn on every edit, so the table turns over.
  # SET (fillfactor) takes SHARE UPDATE EXCLUSIVE: no reader or writer waits.
  def up do
    execute "SET lock_timeout = '5s'"
    execute "ALTER TABLE chunks SET (fillfactor = 90)"
    execute "RESET lock_timeout"
  end

  def down do
    execute "ALTER TABLE chunks RESET (fillfactor)"
  end
end
