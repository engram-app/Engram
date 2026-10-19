defmodule Engram.Repo.Migrations.IndexLinkResolutionKeys do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Lookups by the keys added in AddLinkResolutionKeys.
  #
  # The `*_link_keys_stale_index`es hold only rows whose keys are missing or
  # stale (empty once the backfill has run), so a read finds the rows it must
  # decrypt without visiting every row on a hub basename. Their predicate is
  # `Engram.Links`' stale test with the Unicode version inlined as a literal
  # ("15.1.0" = 0x31352e312e30); Postgres uses a partial index only for a
  # query carrying the same text. `link_keys_index_test.exs` pins the match.
  @stale_note "link_keys_stamp IS DISTINCT FROM (path_nonce || '\\x31352e312e30'::bytea)"
  @stale_link "link_keys_stamp IS DISTINCT FROM (target_text_nonce || '\\x31352e312e30'::bytea)"

  def change do
    create index(:notes, [:user_id, :vault_id, :path_ci_hmac], concurrently: true)
    create index(:attachments, [:user_id, :vault_id, :path_ci_hmac], concurrently: true)
    create index(:note_links, [:user_id, :vault_id, :target_key_hmac], concurrently: true)

    # The shortest same-name candidate: min(path_length) per basename.
    create index(:notes, [:user_id, :vault_id, :basename_hmac, :path_length], concurrently: true)

    create index(:attachments, [:user_id, :vault_id, :basename_hmac, :path_length],
             concurrently: true
           )

    create index(:notes, [:user_id, :vault_id, :basename_hmac],
             name: :notes_link_keys_stale_index,
             where: "basename_hmac IS NOT NULL AND " <> @stale_note,
             concurrently: true
           )

    create index(:attachments, [:user_id, :vault_id, :basename_hmac],
             name: :attachments_link_keys_stale_index,
             where: "basename_hmac IS NOT NULL AND " <> @stale_note,
             concurrently: true
           )

    create index(:note_links, [:user_id, :vault_id, :target_basename_hmac],
             name: :note_links_link_keys_stale_index,
             where: @stale_link,
             concurrently: true
           )
  end
end
