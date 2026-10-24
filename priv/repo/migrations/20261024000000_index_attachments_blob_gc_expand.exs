defmodule Engram.Repo.Migrations.IndexAttachmentsBlobGcExpand do
  use Ecto.Migration

  # phase/expand: new indexes only, no schema change.
  #
  # `AttachmentBlobGC` (#2159) runs hourly: it selects tombstones that still
  # hold a blob (`deleted_at < cutoff AND storage_key IS NOT NULL`) and checks
  # that no live row shares the key. Both partial, so each indexes only the
  # rows its query reads: un-reaped tombstones (a short-lived set once the
  # backlog is gone), and live keys.

  @disable_ddl_transaction true
  @disable_migration_lock true

  # A CONCURRENTLY build that is killed (task replaced mid-deploy) leaves an
  # INVALID index under this name; `create` would then fail every boot. Drop
  # whatever is there first so a retry rebuilds it.
  def up do
    drop_if_exists index(:attachments, [:deleted_at],
                     name: :attachments_blob_gc_tombstones_index,
                     concurrently: true
                   )

    create index(:attachments, [:deleted_at],
             name: :attachments_blob_gc_tombstones_index,
             where: "deleted_at IS NOT NULL AND storage_key IS NOT NULL",
             concurrently: true
           )

    drop_if_exists index(:attachments, [:storage_key],
                     name: :attachments_live_storage_key_index,
                     concurrently: true
                   )

    create index(:attachments, [:storage_key],
             name: :attachments_live_storage_key_index,
             where: "deleted_at IS NULL",
             concurrently: true
           )
  end

  def down do
    drop_if_exists index(:attachments, [:storage_key],
                     name: :attachments_live_storage_key_index,
                     concurrently: true
                   )

    drop_if_exists index(:attachments, [:deleted_at],
                     name: :attachments_blob_gc_tombstones_index,
                     concurrently: true
                   )
  end
end
