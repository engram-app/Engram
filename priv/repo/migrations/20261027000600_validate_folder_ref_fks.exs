defmodule Engram.Repo.Migrations.ValidateFolderRefFks do
  use Ecto.Migration

  # VALIDATE takes SHARE UPDATE EXCLUSIVE: reads and writes continue. Every
  # `folder_ref_id` is NULL when this runs (the backfill is a later release),
  # so the scan checks nothing; it is one pass over notes and attachments.
  def up do
    execute "ALTER TABLE notes VALIDATE CONSTRAINT notes_folder_ref_fk"
    execute "ALTER TABLE attachments VALIDATE CONSTRAINT attachments_folder_ref_fk"
  end

  def down do
    # VALIDATE is not reversible; the constraint stays valid, and the
    # previous migration's down drops it.
    :ok
  end
end
