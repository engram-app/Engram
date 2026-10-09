defmodule Engram.Repo.Migrations.IndexNotesRecent do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Serves Notes.list_recent_notes/4: MCP resources/list keyset paging and the
  # no-query search_notes. Without it every page read the whole vault and
  # sorted (75-170 ms at 47k notes, spilling to disk on deep pages).
  # The predicate matches scoped_live + kind == "note" exactly.
  def change do
    create index(:notes, [:user_id, :vault_id, "updated_at DESC", "id DESC"],
             where: "deleted_at IS NULL AND kind = 'note'",
             name: :notes_recent_index,
             concurrently: true
           )
  end
end
