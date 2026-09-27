defmodule Engram.Repo.Migrations.IndexVaultsSlugHmacExpand do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # phase/expand — CONCURRENTLY, mirroring vaults_user_id_slug_index: one live
  # vault per (user, slug). NULLs are distinct, so rows not yet backfilled
  # (Engram.Workers.BackfillVaultSlugHmac) do not collide.
  def change do
    create unique_index(:vaults, [:user_id, :slug_hmac],
             where: "deleted_at IS NULL",
             name: :vaults_user_id_slug_hmac_index,
             concurrently: true
           )
  end
end
