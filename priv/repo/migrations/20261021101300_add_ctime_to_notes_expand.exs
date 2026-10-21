defmodule Engram.Repo.Migrations.AddCtimeToNotesExpand do
  use Ecto.Migration

  @moduledoc """
  Client file creation time (epoch seconds, same unit as `mtime`), sent by the
  plugin from `file.stat.ctime`. The v5 date fallback uses it so imported
  vaults get a note's real created time instead of the import time.

  Expand-only, nullable, not backfilled: older plugins never send it and an
  update without it leaves the stored value alone. No tenant-table DML, so
  none of the FORCE RLS handling; the existing notes RLS policy covers it.
  """

  def up do
    # Fail fast instead of queueing ACCESS EXCLUSIVE behind a long transaction:
    # the migrator session drops the app's lock_timeout (Release.migrator_config),
    # and a queued ADD COLUMN blocks every read and write of the table behind it.
    # SET LOCAL ends with this migration's transaction; a failed boot retries.
    execute "SET LOCAL lock_timeout = '5s'"

    alter table(:notes) do
      add :ctime, :float
    end
  end

  def down do
    alter table(:notes) do
      remove :ctime
    end
  end
end
