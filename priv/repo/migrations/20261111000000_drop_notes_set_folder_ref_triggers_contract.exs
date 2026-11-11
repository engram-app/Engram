# Shared with 20261111000100 (R8(d)); see the file for why it is not in lib/.
Code.require_file("lock_timeout_retry.exs", __DIR__)

defmodule Engram.Repo.Migrations.DropNotesSetFolderRefTriggersContract do
  use Ecto.Migration

  alias Engram.Repo.Migrations.LockTimeoutRetry

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  R9 release D contract: drops `notes_set_folder_ref` (INSERT or UPDATE OF
  `folder_hmac`), `notes_set_folder_ref_on_restore` (a restore) and their
  function `notes_set_folder_ref()`. Nothing else runs the function.

  Every writer of a note's path sets `folder_ref_id` itself, in this release
  and in every release down to the rollback floor (0.76.0, 0.78.1 and C:
  `writers_set_folder_ref_test.exs` drives each writer with both triggers
  disabled at each of those tags, restores included). A rename tombstone no longer gets a reference: nothing reads a tombstone's
  (a revive goes through `move_note`, which sets it).

  The restore twin also kept a raw restore (`deleted_at` back to NULL, which
  no code in lib/ does) from leaving a live note with a reference to a dead
  folder row, which no listing places and the drain cannot find (its index,
  `notes_unresolved_folder`, matches a NULL reference). So
  `notes_folder_ref_live_only` (20261107090000) now also fires on
  `UPDATE OF deleted_at`: its function returns at once for a deleted row and
  NULLs a dead reference on a live one, so a restored note lands on the
  drift path the drain heals. Cost: one `folders` primary-key probe per
  restored note; a soft delete returns before the probe.

  `DROP TRIGGER` takes ACCESS EXCLUSIVE on `notes` for a catalog change
  only: no scan, no rewrite, under `lock_timeout` 5s. A statement that hits
  it (55P03) is retried twice (`LockTimeoutRetry`), so a busy `notes` table
  does not fail boot; after that the migration raises, the task exits, ECS
  replaces it, and repeated failures trip the circuit breaker and roll the
  deploy back. No DDL transaction, so one statement can be retried alone:
  each leaves a state every release down to the floor runs on (writers set
  `folder_ref_id` themselves), and `notes_folder_ref_live_only` is replaced
  in one `CREATE OR REPLACE TRIGGER`, so it is never missing. Rerun-safe
  (`IF EXISTS`, `OR REPLACE`), so a replacement task starts clean. Calls no
  app module (N-1 gate). Down restores the release C function and both
  triggers.
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

  def up, do: run_up(repo())
  def down, do: run_down(repo())

  @doc false
  # Public for `DropFolderRefTriggersLockTest`.
  def run_up(repo) do
    LockTimeoutRetry.with_lock_timeout(repo, [
      "DROP TRIGGER IF EXISTS notes_set_folder_ref ON notes",
      "DROP TRIGGER IF EXISTS notes_set_folder_ref_on_restore ON notes",
      "DROP FUNCTION IF EXISTS notes_set_folder_ref()",
      live_only_trigger("folder_ref_id, deleted_at")
    ])
  end

  @doc false
  def run_down(repo) do
    LockTimeoutRetry.with_lock_timeout(repo, [
      live_only_trigger("folder_ref_id"),
      @set_ref,
      """
      CREATE OR REPLACE TRIGGER notes_set_folder_ref
        BEFORE INSERT OR UPDATE OF folder_hmac ON notes
        FOR EACH ROW WHEN (NEW.kind = 'note')
        EXECUTE FUNCTION notes_set_folder_ref()
      """,
      """
      CREATE OR REPLACE TRIGGER notes_set_folder_ref_on_restore
        BEFORE UPDATE OF deleted_at ON notes
        FOR EACH ROW
        WHEN (NEW.kind = 'note' AND OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL)
        EXECUTE FUNCTION notes_set_folder_ref()
      """
    ])
  end

  defp live_only_trigger(columns) do
    """
    CREATE OR REPLACE TRIGGER notes_folder_ref_live_only
      BEFORE INSERT OR UPDATE OF #{columns} ON notes
      FOR EACH ROW
      EXECUTE FUNCTION folder_ref_live_only()
    """
  end
end
