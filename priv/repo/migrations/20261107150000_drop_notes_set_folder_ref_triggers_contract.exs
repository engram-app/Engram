defmodule Engram.Repo.Migrations.DropNotesSetFolderRefTriggersContract do
  use Ecto.Migration

  @moduledoc """
  R9 release D contract: drops `notes_set_folder_ref` (INSERT or UPDATE OF
  `folder_hmac`), `notes_set_folder_ref_on_restore` (a restore) and their
  function `notes_set_folder_ref()`. Nothing else runs the function.

  Every writer of a note's path sets `folder_ref_id` itself, in this release
  and in every release down to the rollback floor (0.76.0, 0.78.1 and C:
  `writers_set_folder_ref_test.exs` drives each writer with both triggers
  disabled at each of those tags, restores included). A rename tombstone no longer gets a reference: nothing reads a tombstone's
  (a revive goes through `move_note`, which sets it). A raw restore of a
  note whose reference names a dead folder row keeps that reference; there
  is none in lib/, and the drain heals such a row (`notes_unresolved_folder`).

  `DROP TRIGGER` takes ACCESS EXCLUSIVE on `notes` for a catalog change
  only: no scan, no rewrite, under `lock_timeout` 5s (the boot migrator
  retries). Rerun-safe (`IF EXISTS`). Calls no app module (N-1 gate). Down
  restores the release C function and both triggers.
  """

  @set_ref """
  CREATE OR REPLACE FUNCTION notes_set_folder_ref() RETURNS trigger
  LANGUAGE plpgsql SET search_path = '' AS $$
  BEGIN
    IF NEW.folder_hmac IS NULL THEN
      IF NEW.folder_ref_id IS NOT NULL AND EXISTS (
           SELECT 1 FROM public.folders f
           WHERE f.id = NEW.folder_ref_id AND f.deleted_at IS NOT NULL) THEN
        NEW.folder_ref_id := NULL;
      END IF;
      RETURN NEW;
    END IF;

    NEW.folder_ref_id := (
      SELECT f.id FROM public.folders f
      WHERE f.vault_id = NEW.vault_id
        AND f.full_path_hmac = NEW.folder_hmac
        AND f.deleted_at IS NULL
      LIMIT 1);
    RETURN NEW;
  END
  $$
  """

  def up do
    execute "SET lock_timeout = '5s'"
    execute "DROP TRIGGER IF EXISTS notes_set_folder_ref ON notes"
    execute "DROP TRIGGER IF EXISTS notes_set_folder_ref_on_restore ON notes"
    execute "DROP FUNCTION IF EXISTS notes_set_folder_ref()"
    execute "RESET lock_timeout"
  end

  def down do
    execute "SET lock_timeout = '5s'"
    execute @set_ref
    execute "DROP TRIGGER IF EXISTS notes_set_folder_ref ON notes"

    execute """
    CREATE TRIGGER notes_set_folder_ref
      BEFORE INSERT OR UPDATE OF folder_hmac ON notes
      FOR EACH ROW WHEN (NEW.kind = 'note')
      EXECUTE FUNCTION notes_set_folder_ref()
    """

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
end
