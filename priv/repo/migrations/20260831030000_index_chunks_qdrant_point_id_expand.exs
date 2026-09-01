defmodule Engram.Repo.Migrations.IndexChunksQdrantPointIdExpand do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # phase/expand — CONCURRENTLY: chunks is a populated table (one row per
  # indexed chunk, so it outgrows `notes` by ~4x).
  #
  # OrphanSweep's point pass asks "which of these 500 Qdrant point ids still
  # have a chunk row" once per scroll page. Without this index that probe is a
  # seq scan of the whole table, per page — the sweep would cost O(pages x rows).
  def change do
    create index(:chunks, [:qdrant_point_id], concurrently: true)
  end
end
