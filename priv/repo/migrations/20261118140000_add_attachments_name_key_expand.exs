# Shared helpers; see each file for why they are not in lib/.
Code.require_file("lock_timeout_retry.exs", __DIR__)
Code.require_file("bounded_index_build.exs", __DIR__)
Code.require_file("migration_log.exs", __DIR__)

defmodule Engram.Repo.Migrations.AddAttachmentsNameKeyExpand do
  use Ecto.Migration

  alias Engram.Repo.Migrations.{BoundedIndexBuild, LockTimeoutRetry, MigrationLog}

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  `attachments.name_key`: the twin of `notes.name_key` (20261113100000) for
  attachments, O(1) folder rename plan S6 step 6 (Engram#2523). A live
  attachment's casefolded name plus its folder row, one stored `bytea`
  (`name_ci_hmac || uuid_send(folder_ref_id)`), for the by-path lookup of
  an attachment shown under a folder moved without a cascade
  (`Engram.Attachments.Location`). A plain column against a bound value, so
  the qual drives the index under FORCE RLS
  (docs/context/rls-leakproof-index-quals.md).

  `attachments_set_name_key` keeps it for every writer (this release, the
  previous one, raw SQL): the key while the row has a folder row whose
  reference is current (`folder_ref_stamp = path_nonce`,
  `Engram.Folders.Rows.attachment_ref/2`) and current name keys
  (`name_stamp = path_nonce || '\\x01'`, `Engram.Crypto.NameKeys.stamp/1`),
  else NULL. So a stale name or a stale folder reference never answers by
  name, and a row with a NULL key is read at its stored path. It only
  assigns `NEW` and fires on a statement listing one of its inputs, which
  `name_key` is not: it cannot loop. Cost: one plpgsql call per insert and
  per update naming an input; a content save names `path_nonce` only when
  the path is re-encrypted.

  `attachments_name_key_live (vault_id, name_key)`, partial on live keyed
  rows, serves that lookup. No other query names `name_key`.

  Expand only: the previous release ignores the column, the trigger and the
  index. ADD COLUMN with no default is catalog-only; rows written before
  this release keep a NULL key until a writer touches an input or the
  `attachment_name_key` ledger (`Engram.DataMigrations.AttachmentNameKey`)
  touches them. Both CONCURRENTLY builds share one BoundedIndexBuild budget
  (110 s; an overrun is cancelled, left INVALID, and the next boot drops and
  rebuilds it). `attachments_name_key_live` holds only the keyed rows (none
  at boot, so it reads the heap and writes nothing).
  `attachments_folder_ref_live_id` indexes EVERY live attachment: its build
  is the cost, one heap pass plus a sort of (vault_id, folder_ref_id, id,
  user_id) per live row.

  The trigger inlines the name stamp's version byte (`'\\x01'`,
  `Engram.Crypto.NameKeys.version/0`) as `notes_set_name_key` does: a bump
  of that version ships a new trigger, or the `attachment_name_key` ledger
  (which reads the version at runtime) would chase rows the trigger never
  keys.
  """

  def up do
    started = MigrationLog.now()

    LockTimeoutRetry.with_lock_timeout(repo(), [
      "ALTER TABLE attachments ADD COLUMN IF NOT EXISTS name_key bytea",
      """
      CREATE OR REPLACE FUNCTION attachments_set_name_key() RETURNS trigger
      LANGUAGE plpgsql SET search_path = '' AS $$
      BEGIN
        NEW.name_key := CASE
          WHEN NEW.folder_ref_id IS NOT NULL
               AND NEW.name_ci_hmac IS NOT NULL
               AND NEW.folder_ref_stamp = NEW.path_nonce
               AND NEW.name_stamp = NEW.path_nonce || '\\x01'::bytea
          THEN NEW.name_ci_hmac || uuid_send(NEW.folder_ref_id)
        END;
        RETURN NEW;
      END
      $$
      """,
      """
      CREATE OR REPLACE TRIGGER attachments_set_name_key
        BEFORE INSERT OR UPDATE OF folder_ref_id, folder_ref_stamp, name_ci_hmac, name_stamp, path_nonce, deleted_at
        ON attachments
        FOR EACH ROW EXECUTE FUNCTION attachments_set_name_key()
      """
    ])

    BoundedIndexBuild.build!(
      repo(),
      [
        {"attachments_name_key_live",
         "ON attachments (vault_id, name_key) WHERE name_key IS NOT NULL AND deleted_at IS NULL"},
        # The moved-folder feed's attachment leg: a folder's live attachments
        # in id order (`Engram.Attachments.list_moved_changes/4`), the twin of
        # `notes_folder_ref_live_id`.
        {"attachments_folder_ref_live_id",
         "ON attachments (vault_id, folder_ref_id, id) INCLUDE (user_id) WHERE deleted_at IS NULL"}
      ],
      lock_key: 20_261_118_140_000,
      label: "add_attachments_name_key"
    )

    MigrationLog.indexes(
      repo(),
      "add_attachments_name_key",
      ~w(attachments_name_key_live attachments_folder_ref_live_id),
      started
    )
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS attachments_folder_ref_live_id"
    execute "DROP INDEX CONCURRENTLY IF EXISTS attachments_name_key_live"
    execute "DROP TRIGGER IF EXISTS attachments_set_name_key ON attachments"
    execute "DROP FUNCTION IF EXISTS attachments_set_name_key()"
    alter table(:attachments), do: remove_if_exists(:name_key, :binary)
  end
end
