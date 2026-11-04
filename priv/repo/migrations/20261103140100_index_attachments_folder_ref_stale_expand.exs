defmodule Engram.Repo.Migrations.IndexAttachmentsFolderRefStaleExpand do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  `attachments_folder_ref_stale`: the live attachments whose `folder_ref_id`
  was not computed from their current path (`folder_ref_stamp` differs from
  `path_nonce`). `BookkeepingDrain` finds their users through it and hands them
  to `FolderTable`, which replaces that migration's nightly re-verify walk.
  Its predicate must equal the drain probe's text (`drain_test.exs` pins it).

  A row whose path did not decrypt is stamped `'\\x00' || path_nonce`
  (`Rows.unreadable_attachment_stamp/1`) and leaves the index until a writer
  gives it a fresh nonce, so one unreadable row cannot re-queue its user on
  every drain tick.

  Empty in steady state: every writer stamps (`Rows.attachment_ref/2`). It
  holds every live attachment between this migration and the end of the
  `FolderTable` version 2 pass that stamps them.

  HOT: every predicate column is already in an attachments index expression
  (`path_nonce` in `attachments_link_keys_stale_index`, `deleted_at` in the
  live-path indexes) or changes only with `path_nonce` (`folder_ref_stamp`), so
  no update that was heap-only stops being one. A non-HOT update whose row is
  stamped adds no entry here.

  Additive: the previous release ignores it. Dropped by name first, so a retry
  after a failed CONCURRENTLY build rebuilds an INVALID index.
  """

  def up do
    execute "DROP INDEX CONCURRENTLY IF EXISTS attachments_folder_ref_stale"

    execute """
    CREATE INDEX CONCURRENTLY attachments_folder_ref_stale ON attachments (user_id)
    WHERE deleted_at IS NULL AND folder_ref_stamp IS DISTINCT FROM path_nonce
      AND folder_ref_stamp IS DISTINCT FROM ('\\x00'::bytea || path_nonce)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS attachments_folder_ref_stale"
  end
end
