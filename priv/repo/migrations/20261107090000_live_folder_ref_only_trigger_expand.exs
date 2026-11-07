defmodule Engram.Repo.Migrations.LiveFolderRefOnlyTriggerExpand do
  use Ecto.Migration

  @moduledoc """
  `folder_ref_live_only`: a live note or attachment can never be written with
  a `folder_ref_id` that names a soft-deleted folder row. Any writer of any
  release that sets one (FolderTable pointing at a row it found earlier in its
  pass, a raw repair, an old release) gets NULL instead, and an attachment
  also loses its stamp. The row then sits on the drift path every folder
  reader already places by its decrypted folder (`notes_unresolved_folder`,
  `attachments_folder_ref_stale`) and the drain heals: it is never invisible.

  The twin of `folders_release_refs` (20261106100200), which NULLs the
  references a folder row has when it dies; this covers a reference written
  after. The folder row is read `FOR SHARE`, which conflicts with the
  `FOR NO KEY UPDATE` of a soft delete: a delete committing meanwhile is
  waited for and then seen (READ COMMITTED re-reads the locked row), and a
  delete that comes after waits for this write, so its release statement
  sees the new reference. Cost: one primary-key probe and a share lock per
  write that SETS the column (an UPDATE naming `folder_ref_id`, an INSERT
  with one); a NULL reference returns at once. Tombstones keep theirs (the
  restore trigger re-resolves them).

  BEFORE ROW, so the write itself carries the NULL (no second UPDATE).
  `UPDATE OF folder_ref_id` fires only when the statement names the column;
  a reference another BEFORE trigger derives (`notes_set_folder_ref`) is
  already resolved against live rows. No app module is called (N-1 gate).
  """

  def up do
    execute "SET lock_timeout = '5s'"

    execute """
    CREATE OR REPLACE FUNCTION folder_ref_live_only() RETURNS trigger
    LANGUAGE plpgsql SET search_path = '' AS $$
    DECLARE
      dead timestamptz;
    BEGIN
      IF NEW.folder_ref_id IS NULL OR NEW.deleted_at IS NOT NULL THEN
        RETURN NEW;
      END IF;

      SELECT f.deleted_at INTO dead FROM public.folders f
        WHERE f.id = NEW.folder_ref_id FOR SHARE;

      IF dead IS NOT NULL THEN
        NEW.folder_ref_id := NULL;
        IF TG_TABLE_NAME = 'attachments' THEN
          NEW.folder_ref_stamp := NULL;
        END IF;
      END IF;

      RETURN NEW;
    END
    $$
    """

    for table <- ~w(notes attachments) do
      execute "DROP TRIGGER IF EXISTS #{table}_folder_ref_live_only ON #{table}"

      execute """
      CREATE TRIGGER #{table}_folder_ref_live_only
        BEFORE INSERT OR UPDATE OF folder_ref_id ON #{table}
        FOR EACH ROW
        EXECUTE FUNCTION folder_ref_live_only()
      """
    end

    execute "RESET lock_timeout"
  end

  def down do
    for table <- ~w(notes attachments) do
      execute "DROP TRIGGER IF EXISTS #{table}_folder_ref_live_only ON #{table}"
    end

    execute "DROP FUNCTION IF EXISTS folder_ref_live_only()"
  end
end
