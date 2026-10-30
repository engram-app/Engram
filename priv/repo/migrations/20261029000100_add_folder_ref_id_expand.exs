defmodule Engram.Repo.Migrations.AddFolderRefIdExpand do
  use Ecto.Migration

  @moduledoc """
  `folder_ref_id`: the row id of the folder a note or attachment sits in
  (`folders.id`). Named `_ref_` because `notes.folder_id` already means the
  uuid of `folder_hmac`'s first 16 bytes (20261021110000).

  Nullable, no default: metadata only, no rewrite. NULL is "not resolved":
  the folder has no row yet (an older release made it) or the item is in the
  vault root. Filled by the `notes_set_folder_ref` trigger (notes) and the
  `FolderTable` data migration (both). Nothing reads it yet.

  One column on `notes`, on purpose: it is near the heap-header width
  threshold (20261021110000), so each added attribute costs.
  """

  def up do
    execute "SET lock_timeout = '5s'"
    execute "ALTER TABLE notes ADD COLUMN folder_ref_id uuid"
    execute "ALTER TABLE attachments ADD COLUMN folder_ref_id uuid"
    execute "RESET lock_timeout"
  end

  def down do
    execute "DELETE FROM data_migrations WHERE name = 'folder_table'"
    execute "ALTER TABLE attachments DROP COLUMN IF EXISTS folder_ref_id"
    execute "ALTER TABLE notes DROP COLUMN IF EXISTS folder_ref_id"
  end
end
