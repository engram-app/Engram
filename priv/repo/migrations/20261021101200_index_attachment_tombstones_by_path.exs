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
  def change do
    create index(:attachments, [:vault_id, :path_hmac],
             name: :attachments_vault_path_tombstone_index,
             where: "deleted_at IS NOT NULL",
             concurrently: true
           )
  end
end
