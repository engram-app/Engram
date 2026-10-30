defmodule Engram.Repo.Migrations.AddFolderRefFksExpand do
  use Ecto.Migration

  @moduledoc """
  The composite foreign keys `(vault_id, folder_ref_id)` -> `folders
  (vault_id, id)` on notes and attachments, added NOT VALID: new and updated
  rows are checked at once, existing rows are not scanned. The next migration
  validates them.

  A composite key because the vault is part of it: a note cannot reference
  another vault's folder. MATCH SIMPLE, so a NULL `folder_ref_id` is not
  checked. `ON DELETE SET NULL (folder_ref_id)` nulls only that column (not
  `vault_id`) when a folder row is hard-deleted. Folders are soft-deleted
  (`deleted_at`), so that happens on a vault purge or a pruning pass.
  """

  def up do
    # ADD FOREIGN KEY takes SHARE ROW EXCLUSIVE on both tables.
    execute "SET lock_timeout = '5s'"

    for table <- ~w(notes attachments) do
      execute """
      ALTER TABLE #{table} ADD CONSTRAINT #{table}_folder_ref_fk
        FOREIGN KEY (vault_id, folder_ref_id) REFERENCES folders (vault_id, id)
        ON DELETE SET NULL (folder_ref_id) NOT VALID
      """
    end

    execute "RESET lock_timeout"
  end

  def down do
    execute "ALTER TABLE attachments DROP CONSTRAINT IF EXISTS attachments_folder_ref_fk"
    execute "ALTER TABLE notes DROP CONSTRAINT IF EXISTS notes_folder_ref_fk"
  end
end
