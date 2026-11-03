defmodule Engram.Repo.Migrations.AddAttachmentsFolderRefStampExpand do
  use Ecto.Migration

  @moduledoc """
  `attachments.folder_ref_stamp`: the `path_nonce` the row's `folder_ref_id`
  was computed from. A reference is current only while its stamp equals the
  row's `path_nonce`; every path write draws a fresh nonce, so a writer that
  rewrites the path without re-pointing the reference (the previous release
  during a rolling deploy, a DEK rotation that loses the race) leaves a
  mismatch that readers distrust and `BookkeepingDrain` heals.

  Nullable, no default: a catalog-only change. NULL is "never stamped", which
  is a mismatch; `FolderTable` version 2 stamps every existing row.
  """

  def up do
    execute "SET lock_timeout = '5s'"
    execute "ALTER TABLE attachments ADD COLUMN IF NOT EXISTS folder_ref_stamp bytea"
    execute "RESET lock_timeout"
  end

  def down do
    execute "ALTER TABLE attachments DROP COLUMN IF EXISTS folder_ref_stamp"
  end
end
