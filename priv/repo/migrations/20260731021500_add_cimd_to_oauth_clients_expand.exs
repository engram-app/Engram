defmodule Engram.Repo.Migrations.AddCimdToOauthClientsExpand do
  use Ecto.Migration

  # phase/expand — purely additive: two nullable columns and one index.
  #
  # CIMD (Client ID Metadata Documents, IETF
  # draft-ietf-oauth-client-id-metadata-document, adopted by MCP 2025-11-25)
  # makes a client's `client_id` an HTTPS URL the vendor owns, which the
  # authorization server fetches to obtain the client's metadata.
  #
  # WHY A COLUMN RATHER THAN A WIDER PRIMARY KEY. `oauth_clients.client_id` is
  # the primary key and is a uuid; CIMD ids are URLs. Widening the PK would
  # touch `oauth_authorization_codes.client_id` and
  # `oauth_refresh_tokens.client_id` (both bare uuid columns) plus every join,
  # for no gain: the URL only ever needs to appear at the wire boundary. So
  # UUIDs stay internal and `cimd_url` is the lookup key that maps a wire
  # client_id to its row. See Engram.OAuth.get_client/1.
  #
  # `cimd_fetched_at` is the cache clock. The row IS the document cache — a
  # separate ETS/GenServer cache would add a second source of truth for data
  # that already has to be durable (the redirect allowlist is derived from it).
  # A NULL here means "not a CIMD client", same as a NULL cimd_url.
  #
  # The unique index is what makes `cimd_url` a usable identity: it is both the
  # lookup path on every authorize and the constraint that keeps two rows from
  # claiming one vendor URL (the upsert in Engram.OAuth.Cimd targets it).
  # Created CONCURRENTLY per squawk require-concurrent-index-creation, which
  # requires running outside the DDL transaction.
  #
  # No backfill, no default, no NOT NULL: every existing DCR row keeps NULL in
  # both columns and is unaffected. Nothing reads these until
  # `config :engram, :cimd_enabled` is true, which defaults to false.

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    alter table(:oauth_clients) do
      add :cimd_url, :text
      add :cimd_fetched_at, :utc_datetime_usec
    end

    # Partial: only CIMD rows are indexed, so the DCR majority costs nothing to
    # maintain. NULLs are distinct in a Postgres unique index anyway, so the
    # predicate is about index size rather than correctness.
    create index(:oauth_clients, [:cimd_url],
             name: :oauth_clients_cimd_url_index,
             unique: true,
             where: "cimd_url IS NOT NULL",
             concurrently: true
           )
  end
end
