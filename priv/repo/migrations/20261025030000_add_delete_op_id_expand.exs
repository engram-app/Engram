defmodule Engram.Repo.Migrations.AddDeleteOpIdExpand do
  use Ecto.Migration

  # phase/expand: one nullable column per table, no backfill, no default.
  #
  # Safer delete (#609): every MCP delete stamps the rows it soft-deletes
  # with one `delete_op_id`, so `Engram.Folders.restore_op/3` can bring back
  # exactly what that call removed. NULL means "not deleted by an undoable
  # op", which is every existing row, every live row, and every rename
  # tombstone (those are never stamped). A restore clears it.
  def change do
    alter table(:notes) do
      add :delete_op_id, :uuid
    end

    alter table(:attachments) do
      add :delete_op_id, :uuid
    end
  end
end
