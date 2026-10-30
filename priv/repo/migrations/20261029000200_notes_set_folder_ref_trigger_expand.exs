defmodule Engram.Repo.Migrations.NotesSetFolderRefTriggerExpand do
  use Ecto.Migration

  @moduledoc """
  Keeps `notes.folder_ref_id` in step with `notes.folder_hmac` for EVERY
  writer, the way `notes_derive_core_keys` (20261021110200) does for the
  narrow keys: this release's code, the previous release's nodes during a
  rolling deploy, raw SQL.

  BEFORE INSERT OR UPDATE OF `folder_hmac`, notes only (a `kind = 'folder'`
  marker's `folder_hmac` is its own path; its folder row is the marker's id).
  It sets the column from the live `folders` row whose `full_path_hmac`
  equals the note's `folder_hmac` in the same vault, else NULL. A folder the
  previous release created has no row yet, so its notes stay NULL until the
  `FolderTable` data migration (or a new writer) creates the row.

  It cannot loop: it assigns `NEW` in a BEFORE trigger and fires only on a
  statement that lists `folder_hmac`. `notes_derive_core_keys` and the
  `notes_sync_*` triggers fire on their own column lists, which do not
  contain `folder_ref_id`, so a statement that sets only `folder_ref_id`
  (the backfill) fires none of them. The lookup is `folders_full_path`.
  """

  def up do
    # CREATE TRIGGER takes SHARE ROW EXCLUSIVE on notes: fail fast, the boot
    # migrator retries.
    execute "SET lock_timeout = '5s'"

    execute """
    CREATE FUNCTION notes_set_folder_ref() RETURNS trigger
    LANGUAGE plpgsql SET search_path = '' AS $$
    BEGIN
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

    execute """
    CREATE TRIGGER notes_set_folder_ref
      BEFORE INSERT OR UPDATE OF folder_hmac ON notes
      FOR EACH ROW WHEN (NEW.kind = 'note')
      EXECUTE FUNCTION notes_set_folder_ref()
    """

    execute "RESET lock_timeout"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS notes_set_folder_ref ON notes"
    execute "DROP FUNCTION IF EXISTS notes_set_folder_ref()"
  end
end
