defmodule Engram.Repo.Migrations.PartialNoteLinksTargetIndexes do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # note_links (target_note_id, user_id, vault_id) and (target_attachment_id,
  # user_id, vault_id) indexed every edge, though most never resolve to an
  # attachment and dangling ones resolve to nothing: mostly NULL keys, each
  # about 58 bytes, plus the two trailing columns no lookup needs (the target
  # id alone is selective; user/vault stay filters). Every lookup is
  # `target_* = $1`, which implies `target_* IS NOT NULL`, so the partial
  # indexes serve them all, the FKs' ON DELETE SET NULL actions included (the
  # FK lint accepts a partial index). Created before the old ones go, so a
  # lookup is never left without one. NoteLinksTargetIndexPlanTest pins the
  # plans.
  #
  # Kept from the same audit item: note_links (user_id, vault_id,
  # source_note_id), 99,955 prod scans since June.
  def up do
    # A CONCURRENTLY build that fails (lock timeout, deploy kill) leaves an
    # INVALID index under its name, which a retry would skip or trip on.
    # Dropping the name first makes the retry rebuild it.
    drop_if_exists index(:note_links, [],
                     name: :note_links_target_note_id_index,
                     concurrently: true
                   )

    drop_if_exists index(:note_links, [],
                     name: :note_links_target_attachment_id_index,
                     concurrently: true
                   )

    create index(:note_links, [:target_note_id],
             name: :note_links_target_note_id_index,
             where: "target_note_id IS NOT NULL",
             concurrently: true
           )

    create index(:note_links, [:target_attachment_id],
             name: :note_links_target_attachment_id_index,
             where: "target_attachment_id IS NOT NULL",
             concurrently: true
           )

    drop_if_exists index(:note_links, [:target_note_id, :user_id, :vault_id], concurrently: true)

    drop_if_exists index(:note_links, [:target_attachment_id, :user_id, :vault_id],
                     concurrently: true
                   )
  end

  def down do
    create_if_not_exists index(:note_links, [:target_note_id, :user_id, :vault_id],
                           concurrently: true
                         )

    create_if_not_exists index(:note_links, [:target_attachment_id, :user_id, :vault_id],
                           concurrently: true
                         )

    drop_if_exists index(:note_links, [:target_note_id],
                     name: :note_links_target_note_id_index,
                     concurrently: true
                   )

    drop_if_exists index(:note_links, [:target_attachment_id],
                     name: :note_links_target_attachment_id_index,
                     concurrently: true
                   )
  end
end
