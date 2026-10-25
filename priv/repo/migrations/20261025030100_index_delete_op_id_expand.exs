defmodule Engram.Repo.Migrations.IndexDeleteOpIdExpand do
  use Ecto.Migration

  # phase/expand: new indexes only.
  #
  # `restore_op/3` looks rows up by `delete_op_id`. Partial on NOT NULL, so
  # each indexes only the rows a restorable delete stamped (trash), not the
  # live tables.

  @disable_ddl_transaction true
  @disable_migration_lock true

  # A CONCURRENTLY build that is killed leaves an INVALID index under this
  # name; drop whatever is there first so a retry rebuilds it.
  def up do
    for table <- [:notes, :attachments] do
      name = :"#{table}_delete_op_id_index"
      drop_if_exists index(table, [:delete_op_id], name: name, concurrently: true)

      create index(table, [:delete_op_id],
               name: name,
               where: "delete_op_id IS NOT NULL",
               concurrently: true
             )
    end
  end

  def down do
    for table <- [:attachments, :notes] do
      drop_if_exists index(table, [:delete_op_id],
                       name: :"#{table}_delete_op_id_index",
                       concurrently: true
                     )
    end
  end
end
