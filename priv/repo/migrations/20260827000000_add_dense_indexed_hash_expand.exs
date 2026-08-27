defmodule Engram.Repo.Migrations.AddDenseIndexedHashExpand do
  use Ecto.Migration

  @moduledoc """
  Splits the two facts `embed_hash` was carrying.

  `embed_hash` meant both "this content is indexed" (what `EmbedNote.perform/1`
  skips on) and "this note has dense vectors in Qdrant" (what an upgrade needs).
  Those stay equal only while every tier gets dense vectors. Once Free is
  keyword-only they diverge, and either stamping of the single column breaks:

    * not stamping leaves every Free note permanently eligible for
      `ReconcileEmbeddings`, which re-enqueues it every 15 minutes forever
    * stamping means an upgraded (paying) user gets semantic search over zero
      vectors, silently, because nothing will ever re-embed those notes

  So `embed_hash` keeps its "content is indexed" meaning and `dense_indexed_hash`
  carries "has dense vectors". `ReconcileEmbeddings` keys off the new column and
  an entitlement check, which makes an upgrade self-healing — the existing cron
  notices and backfills. No upgrade hook to forget or fail.

  Backfill is in-migration because every existing row was dense-indexed under the
  old single-meaning column, and the table is small pre-launch. If this ever runs
  against a large `notes` table, split the UPDATE into batches first.
  """

  def up do
    alter table(:notes) do
      add :dense_indexed_hash, :string
    end

    execute "UPDATE notes SET dense_indexed_hash = embed_hash WHERE embed_hash IS NOT NULL"
  end

  def down do
    alter table(:notes) do
      remove :dense_indexed_hash
    end
  end
end
