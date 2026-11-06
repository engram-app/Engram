defmodule Engram.Repo.Migrations.FoldersReleaseRefsTriggerExpand do
  use Ecto.Migration

  @moduledoc """
  `folders_release_refs`: when a folder row is soft-deleted, the live notes
  and attachments that still name it at COMMIT lose the reference, for every
  writer of any release (the soft-delete twin of the `ON DELETE SET NULL`
  foreign keys of 20261029000400/500, which fire only on a hard delete).

  Without it a reference could name a dead row while every drift index stayed
  empty (the #2466 review, H1): a rename that merged into an existing folder
  retires the source row (`Rows.retire/2`) under notes written into it after
  the rename's scan, and nothing ever looked again. Now the reference is NULL,
  which `BookkeepingDrain` already finds and heals:

    * a note: `notes_unresolved_folder` (20261103130200);
    * an attachment: its stamp is cleared too, so `attachments_folder_ref_stale`
      (20261103140100) holds it. A NULL reference with a current stamp would be
      trusted by readers as "at the root".

  A CONSTRAINT trigger, DEFERRABLE INITIALLY DEFERRED: it runs at commit, so a
  merge rename, which retires the source row BEFORE its bulk update re-points
  the moved notes at the keeper, releases only the stragglers instead of
  writing every moved note twice. Fired only on the live-to-deleted flip, and
  it does nothing if the row is live again by commit (a revive in the same
  transaction). Live rows only (`kind = 'note'` for notes): the statements
  are served by `notes_folder_ref_live` / `attachments_folder_ref_live`
  (20261106100000/100), so the cost is O(live references), not the folder's
  deleted history, and 0 on a recursive delete, which deletes the content
  first. A deleted note keeps its reference (the restore trigger of
  20261103140200 re-resolves it).

  The statements list only the reference columns, so no notes trigger fires
  (`notes_set_folder_ref` is `UPDATE OF folder_hmac`) and `seq` and
  `updated_at` stay put: no sync feed sees a change. Every soft delete of a
  folder row runs under the vault row lock (`Rows.soft_delete/4` and the
  rename that calls `retire/2`), which every note and attachment writer takes
  first, so a write is either committed and released here or made after and
  resolved against the dead row (NULL). Every caller today is a request in
  the `:write` class, whose 5s `statement_timeout` also bounds the work done
  at COMMIT; a future background caller needs its own bound.

  Runs as the invoking role, in the folder writer's tenant scope: the rows it
  touches are that tenant's. No app module is called (N-1 gate).
  """

  def up do
    # CREATE TRIGGER takes SHARE ROW EXCLUSIVE on folders only (not on notes or
    # attachments); DROP TRIGGER IF EXISTS on a missing trigger takes none.
    # Fail fast, the boot migrator retries. (CREATE OR REPLACE is not
    # supported for a constraint trigger.)
    execute "SET lock_timeout = '5s'"

    execute """
    CREATE OR REPLACE FUNCTION folders_release_refs() RETURNS trigger
    LANGUAGE plpgsql SET search_path = '' AS $$
    BEGIN
      IF EXISTS (SELECT 1 FROM public.folders WHERE id = NEW.id AND deleted_at IS NULL) THEN
        RETURN NULL;
      END IF;
      UPDATE public.notes SET folder_ref_id = NULL
        WHERE vault_id = NEW.vault_id AND folder_ref_id = NEW.id
          AND deleted_at IS NULL AND kind = 'note';
      UPDATE public.attachments SET folder_ref_id = NULL, folder_ref_stamp = NULL
        WHERE vault_id = NEW.vault_id AND folder_ref_id = NEW.id AND deleted_at IS NULL;
      RETURN NULL;
    END
    $$
    """

    execute "DROP TRIGGER IF EXISTS folders_release_refs ON folders"

    execute """
    CREATE CONSTRAINT TRIGGER folders_release_refs
      AFTER UPDATE OF deleted_at ON folders
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW
      WHEN (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
      EXECUTE FUNCTION folders_release_refs()
    """

    execute "RESET lock_timeout"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS folders_release_refs ON folders"
    execute "DROP FUNCTION IF EXISTS folders_release_refs()"
  end
end
