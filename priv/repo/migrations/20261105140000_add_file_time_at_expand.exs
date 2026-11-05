defmodule Engram.Repo.Migrations.AddFileTimeAtExpand do
  use Ecto.Migration

  @moduledoc """
  phase/expand: timestamptz beside each client file-time double,
  `notes.mtime_at` / `ctime_at`, `attachments.mtime_at`,
  `attachment_uploads.mtime_at`. Written by every writer through
  `Engram.FileTime` (seconds or milliseconds normalized, 0 is NULL); the
  doubles are written exactly as before, and the previous release reads
  only them. No backfill and no index here: the migrate-data phase fills old
  rows and moves the readers, the contract phase drops the doubles.

  Nullable, no default: catalog-only, `lock_timeout` so a busy table fails
  the deploy fast instead of queueing writers behind the lock.
  """

  @cols [
    notes: ~w(mtime_at ctime_at),
    attachments: ~w(mtime_at),
    attachment_uploads: ~w(mtime_at)
  ]

  def up do
    execute "SET lock_timeout = '5s'"

    for {table, cols} <- @cols, col <- cols do
      execute "ALTER TABLE #{table} ADD COLUMN IF NOT EXISTS #{col} timestamptz"
    end

    execute "RESET lock_timeout"
  end

  def down do
    for {table, cols} <- @cols, col <- cols do
      execute "ALTER TABLE #{table} DROP COLUMN IF EXISTS #{col}"
    end
  end
end
