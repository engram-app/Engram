defmodule Engram.Repo.Migrations.DropNotesTagsHmacIndex do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # GIN on notes.tags_hmac: 0 scans in prod since June (2026-10-20 audit), and
  # pure write cost on every tag change (GIN pending list). Nothing in lib/
  # filters with `@>` / `&&` / `= ANY` on tags_hmac: tag filtering runs in
  # Qdrant (search.ex), and the readers here (`tags_hmac != []`, unnest in the
  # daily snapshot) cannot use a GIN index. Not unique, not FK-backing.
  #
  # Reviewed and KEPT from the same audit list:
  #   * notes/attachments (user_id, vault_id, basename_hmac, path_length):
  #     created 2026-10-18 (20261018230001), so "0 scans since June" predates
  #     it; Links' shortest-candidate query (links.ex) reads it.
  #   * users_email_lower_index, vaults_user_id_default_index: UNIQUE, they
  #     enforce invariants (case-insensitive email, one default vault).
  def up do
    drop_if_exists index(:notes, [:tags_hmac], name: :notes_tags_hmac_index, concurrently: true)
  end

  def down do
    create_if_not_exists index(:notes, [:tags_hmac],
                           name: :notes_tags_hmac_index,
                           using: :gin,
                           concurrently: true
                         )
  end
end
