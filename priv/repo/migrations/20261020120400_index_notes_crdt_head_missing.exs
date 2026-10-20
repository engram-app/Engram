defmodule Engram.Repo.Migrations.IndexNotesCrdtHeadMissing do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # The hourly WarmCrdtHeads discovery (`BackfillCrdtHead.enqueue_all/0`)
  # looks for live notes with no crdt_head. crdt_head is NULLed on every CRDT
  # append, so the set is never empty, and with no index every run scanned
  # every note. Same predicate as the query, keyed on vault_id (it groups by
  # vault). Holds only the notes waiting for a head, so it stays small.
  def change do
    create index(:notes, [:vault_id],
             name: :notes_crdt_head_missing_index,
             where: "crdt_head IS NULL AND kind = 'note' AND deleted_at IS NULL",
             concurrently: true
           )
  end
end
