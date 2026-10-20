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
