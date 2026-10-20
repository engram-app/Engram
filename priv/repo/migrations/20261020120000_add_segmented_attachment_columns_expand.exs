defmodule Engram.Repo.Migrations.AddSegmentedAttachmentColumnsExpand do
  use Ecto.Migration

  @moduledoc """
  Columns for attachment content format v2 (`Engram.Attachments.SegmentedCipher`):
  the DEK-wrapped per-file key and its nonce, the upload whose id is bound
  into every segment's AAD, and the segment geometry.

  Expand-only, nullable, not backfilled: v1 rows keep them NULL. No
  tenant-table DML, so none of the FORCE RLS handling.
  """

  def up do
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
