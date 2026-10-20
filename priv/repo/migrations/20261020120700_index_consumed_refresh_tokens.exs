defmodule Engram.Repo.Migrations.IndexConsumedRefreshTokens do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # OAuth `cleanup_expired/0` now deletes a consumed, unrevoked refresh token
  # 24h after its use instead of keeping it until the family expires (every
  # 15-minute rotation left one behind). The predicate is the cleanup's own,
  # so the planner can use the index, and it holds only a day of rotations.
  def change do
    create index(:oauth_refresh_tokens, [:consumed_at],
             name: :oauth_refresh_tokens_consumed_unrevoked_index,
             where: "consumed_at IS NOT NULL AND revoked_at IS NULL",
             concurrently: true
           )
  end
end
