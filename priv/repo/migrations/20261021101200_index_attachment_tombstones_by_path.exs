defmodule Engram.Repo.Migrations.IndexAttachmentTombstonesByPath do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Attachment tombstones by path, the twin of
  # notes_vault_path_tombstone_index (20261021090100). The live path index is
  # partial on `deleted_at IS NULL`, so the rename link rewrite's old-path
  # recovery for an attachment (`RewriteNoteLinks.tombstone_old_path/4`) read
  # every tombstone of the vault, and attachment tombstones are never purged.
  # AttachmentsTombstoneIndexPlanTest pins the plan.
  def up do
    # A CONCURRENTLY build that fails (lock timeout, deploy kill) leaves an
    # INVALID index under its name, which a retry would skip or trip on.
    # Dropping the name first makes the retry rebuild it.
    drop_if_exists index(:attachments, [],
                     name: :attachments_vault_path_tombstone_index,
                     concurrently: true
                   )

    create index(:attachments, [:vault_id, :path_hmac],
             name: :attachments_vault_path_tombstone_index,
             where: "deleted_at IS NOT NULL",
             concurrently: true
           )
  end

  def down do
    drop_if_exists index(:attachments, [],
                     name: :attachments_vault_path_tombstone_index,
                     concurrently: true
                   )
  end
end
