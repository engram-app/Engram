defmodule Engram.Repo.Migrations.AddAttachmentsFolderRefIdExpand do
  use Ecto.Migration

  @moduledoc """
  `attachments.folder_ref_id`: the row id of the folder an attachment sits in
  (`folders.id`). Nullable, no default: metadata only. Filled by the
  `FolderTable` data migration. Nothing reads it yet. See
  20261029000100 for the naming.
  """

  def up do
    execute "SET lock_timeout = '5s'"
    execute "ALTER TABLE attachments ADD COLUMN folder_ref_id uuid"
    execute "RESET lock_timeout"
  end

  def down do
    execute "DELETE FROM data_migrations WHERE name = 'folder_table'"
    execute "ALTER TABLE attachments DROP COLUMN IF EXISTS folder_ref_id"
  end
end
