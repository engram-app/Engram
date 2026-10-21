defmodule Engram.Repo.Migrations.RekeyNoteRevisionsPending do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Every content write bumps its open version's updated_at
  # (Revisions.touch/2). updated_at was the key of note_revisions_pending, and
  # Postgres updates a row in place (HOT, no new index entries) only when no
  # indexed column changes, so each touch wrote an entry into every index of
  # the table. Keyed on note_id (never updated) instead: the finalize job
  # reads by note_id, and the hourly sweep's pending set is small (copies
  # awaiting finalize), so its updated_at cutoff and order stay a filter and a
  # sort. fillfactor 90 leaves room on each page for the in-place version.
  # NoteRevisionsHotTouchTest pins both.
  def up do
    # A CONCURRENTLY build that fails (lock timeout, deploy kill) leaves an
    # INVALID index under its name, which a retry would skip or trip on.
    # Dropping the name first makes the retry rebuild it.
    drop_if_exists index(:note_revisions, [],
                     name: :note_revisions_pending_by_note,
                     concurrently: true
                   )

    create index(:note_revisions, [:note_id],
             name: :note_revisions_pending_by_note,
             where: "pending_ciphertext IS NOT NULL AND finalize_failed_at IS NULL",
             concurrently: true
           )

    drop_if_exists index(:note_revisions, [:updated_at],
                     name: :note_revisions_pending,
                     concurrently: true
                   )

    # SHARE UPDATE EXCLUSIVE: reads and writes carry on. New pages only.
    execute "ALTER TABLE note_revisions SET (fillfactor = 90)"
  end

  def down do
    execute "ALTER TABLE note_revisions RESET (fillfactor)"

    create_if_not_exists index(:note_revisions, [:updated_at],
                           name: :note_revisions_pending,
                           where: "pending_ciphertext IS NOT NULL AND finalize_failed_at IS NULL",
                           concurrently: true
                         )

    drop_if_exists index(:note_revisions, [:note_id],
                     name: :note_revisions_pending_by_note,
                     concurrently: true
                   )
  end
end
