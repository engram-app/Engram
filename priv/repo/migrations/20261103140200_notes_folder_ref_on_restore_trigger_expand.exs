defmodule Engram.Repo.Migrations.NotesFolderRefOnRestoreTriggerExpand do
  use Ecto.Migration

  @moduledoc """
  Re-resolves a note's `folder_ref_id` when the note comes back from the
  trash, for every writer of any release.

  Folder rows are soft-deleted, so the `ON DELETE SET NULL` foreign key
  (20261029000400) never fires for them. A note restored after its folder row
  was soft-deleted (an undo that could not revive the row) kept a reference to
  the dead row, and only `FolderTable`'s nightly re-verify re-pointed it; that
  walk is gone (#2413). This trigger runs the existing `notes_set_folder_ref()`
  on the restore itself: the reference becomes the live row at the note's
  `folder_hmac`, or NULL, which `BookkeepingDrain` already finds
  (`notes_unresolved_folder`) and heals.

  It fires only on a restore (`deleted_at` going from set to NULL), so a
  delete or an ordinary save pays nothing. The function and the existing
  `notes_set_folder_ref` trigger are unchanged. Rows that already point at a
  dead row are re-pointed by the `FolderTable` version 2 pass (its notes step
  selects them).
  """

  def up do
    # CREATE TRIGGER takes SHARE ROW EXCLUSIVE on notes: fail fast, the boot
    # migrator retries.
    execute "SET lock_timeout = '5s'"
    execute "DROP TRIGGER IF EXISTS notes_set_folder_ref_on_restore ON notes"

    execute """
    CREATE TRIGGER notes_set_folder_ref_on_restore
      BEFORE UPDATE OF deleted_at ON notes
      FOR EACH ROW
      WHEN (NEW.kind = 'note' AND OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL)
      EXECUTE FUNCTION notes_set_folder_ref()
    """

    execute "RESET lock_timeout"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS notes_set_folder_ref_on_restore ON notes"
  end
end
