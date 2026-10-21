defmodule Engram.Repo.Migrations.AddSegmentedAttachmentColumnsExpand do
  use Ecto.Migration

  # squawk-ignore: prefer-bigint-over-int
  #
  # segment_size is the fixed part size and segment_count is capped by
  # Uploads' max part count, both far below int range.

  @moduledoc """
  Columns for attachment content format v2 (`Engram.Attachments.SegmentedCipher`):
  the DEK-wrapped per-file key and its nonce, the upload whose id is bound
  into every segment's AAD, and the segment geometry.

  Expand-only, nullable, not backfilled: v1 rows keep them NULL. No
  tenant-table DML, so none of the FORCE RLS handling.
  """

  def up do
    # Fail fast instead of queueing ACCESS EXCLUSIVE on attachments behind a
    # long transaction (the migrator session drops the app's lock_timeout).
    execute "SET LOCAL lock_timeout = '5s'"

    alter table(:attachments) do
      add :wrapped_file_key, :binary
      add :file_key_nonce, :binary
      add :upload_id, :uuid
      add :segment_size, :integer
      add :segment_count, :integer
    end
  end

  def down do
    alter table(:attachments) do
      remove :wrapped_file_key
      remove :file_key_nonce
      remove :upload_id
      remove :segment_size
      remove :segment_count
    end
  end
end
