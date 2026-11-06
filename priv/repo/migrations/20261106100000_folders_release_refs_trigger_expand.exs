defmodule Engram.Repo.Migrations.FoldersReleaseRefsTriggerExpand do
  use Ecto.Migration

  @moduledoc """
  `folders_release_refs`: when a folder row is soft-deleted, the live notes
  and attachments that still name it lose the reference, for every writer of
  any release (the soft-delete twin of the `ON DELETE SET NULL` foreign keys
  of 20261029000400/500, which fire only on a hard delete).

  Without it a reference could name a dead row while every drift index stayed
  empty (the #2466 review, H1): a rename that merged into an existing folder
  retires the source row (`Rows.retire/2`) under notes written into it after
  the rename's scan, and nothing ever looked again. Now the reference is NULL,
  which `BookkeepingDrain` already finds and heals:

    * a note: `notes_unresolved_folder` (20261103130200);
    * an attachment: its stamp is cleared too, so `attachments_folder_ref_stale`
      (20261103140100) holds it. A NULL reference with a current stamp would be
      trusted by readers as "at the root".

  AFTER UPDATE OF `deleted_at`, only on the live-to-deleted flip. Live rows
  only: a deleted note keeps its reference (the restore trigger of
  20261103140200 re-resolves it), so a recursive delete, which deletes the
  content first, rewrites no row twice. Both statements are
  `(vault_id, folder_ref_id)` lookups on `notes_folder_ref` /
  `attachments_folder_ref` (not partial, 20261029000600/700). They list only
  the reference columns, so no notes trigger fires (`notes_set_folder_ref` is
  `UPDATE OF folder_hmac`), `seq` and `updated_at` stay put: no sync feed sees
  a change. Every soft delete of a folder row runs under the vault row lock
  (`Rows.soft_delete/4` and the rename that calls `retire/2`), which every
  note and attachment writer takes first, so a write is either committed and
  released here or made after and resolved against the dead row (NULL).

  Runs as the invoking role, in the folder writer's tenant scope: the rows it
  touches are that tenant's. No app module is called (N-1 gate).
  """

  def up do
    # CREATE TRIGGER takes SHARE ROW EXCLUSIVE on folders only (not on notes or
    # attachments): fail fast, the boot migrator retries.
    execute "SET lock_timeout = '5s'"

    execute """
    CREATE OR REPLACE FUNCTION folders_release_refs() RETURNS trigger
    LANGUAGE plpgsql SET search_path = '' AS $$
    BEGIN
      UPDATE public.notes SET folder_ref_id = NULL
        WHERE vault_id = NEW.vault_id AND folder_ref_id = NEW.id AND deleted_at IS NULL;
      UPDATE public.attachments SET folder_ref_id = NULL, folder_ref_stamp = NULL
        WHERE vault_id = NEW.vault_id AND folder_ref_id = NEW.id AND deleted_at IS NULL;
      RETURN NULL;
    END
    $$
    """

    execute "DROP TRIGGER IF EXISTS folders_release_refs ON folders"

    execute """
    CREATE TRIGGER folders_release_refs
      AFTER UPDATE OF deleted_at ON folders
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
