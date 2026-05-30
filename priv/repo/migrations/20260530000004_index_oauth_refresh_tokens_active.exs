defmodule Engram.Repo.Migrations.IndexOauthRefreshTokensActive do
  use Ecto.Migration

  # CREATE INDEX CONCURRENTLY can't run inside a transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:oauth_refresh_tokens, [:user_id, :client_id],
             where: "revoked_at IS NULL AND consumed_at IS NULL",
             name: :idx_oauth_refresh_tokens_user_client_active,
             concurrently: true)
  end
end
