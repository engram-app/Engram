defmodule Engram.Repo.Migrations.AddNotesFolderRefFkExpand do
  use Ecto.Migration

  @moduledoc """
  The composite foreign key `(vault_id, folder_ref_id)` -> `folders
  (vault_id, id)` on notes, added NOT VALID: new and updated rows are checked at
  once, existing rows are not scanned. A later migration validates it.

  A composite key because the vault is part of it: a row cannot reference
  another vault's folder. MATCH SIMPLE, so a NULL `folder_ref_id` is not
  checked. `ON DELETE SET NULL (folder_ref_id)` nulls only that column (not
  `vault_id`) when a folder row is hard-deleted (a vault purge or a pruning
  pass; folders are otherwise soft-deleted). One table per migration so the
  lock is held on one table at a time.
  """

  def up do
    # ADD FOREIGN KEY takes SHARE ROW EXCLUSIVE on both tables.
    execute "SET lock_timeout = '5s'"

    execute """
    ALTER TABLE notes ADD CONSTRAINT notes_folder_ref_fk
      FOREIGN KEY (vault_id, folder_ref_id) REFERENCES folders (vault_id, id)
      ON DELETE SET NULL (folder_ref_id) NOT VALID
    """

    execute "RESET lock_timeout"
  end

  def down do
    execute "ALTER TABLE notes DROP CONSTRAINT IF EXISTS notes_folder_ref_fk"
  end
end
