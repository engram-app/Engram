defmodule Engram.Repo.Migrations.AddAttachmentsBlobGcClaimedAtExpand do
  use Ecto.Migration

  # phase/expand: one nullable column, no backfill, no new index.
  #
  # `AttachmentBlobGC` claims a tombstone (stamps this) in a short locked
  # transaction, deletes its blob OUTSIDE any transaction, then clears
  # `storage_key` and this stamp. A run that dies in between leaves the
  # stamp, and the tombstone keeps its key, so a later run re-claims it once
  # the stamp is stale: no blob is ever orphaned by a crash. NULL means
  # unclaimed, which every existing row is.
  #
  # No index: eligibility already reads through
  # `attachments_blob_gc_tombstones_index` (deleted_at, partial on
  # `deleted_at IS NOT NULL AND storage_key IS NOT NULL`), and claimed rows
  # still hold their key, so the stamp is a filter on those few rows.
  def change do
    alter table(:attachments) do
      add :blob_gc_claimed_at, :utc_datetime_usec
    end
  end
end
