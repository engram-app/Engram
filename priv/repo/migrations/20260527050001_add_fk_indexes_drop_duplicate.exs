defmodule Engram.Repo.Migrations.AddFkIndexesDropDuplicate do
  use Ecto.Migration

  # Concurrent index builds can't run inside a transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Covering indexes for foreign keys flagged by the advisor
    # (unindexed_foreign_keys) — speeds up joins and cascade deletes.
    create index(:api_keys, [:user_id], concurrently: true)
    create index(:api_key_vaults, [:vault_id], concurrently: true)
    create index(:device_authorizations, [:user_id], concurrently: true)
    create index(:device_authorizations, [:vault_id], concurrently: true)
    create index(:device_refresh_tokens, [:vault_id], concurrently: true)
    create index(:oauth_authorization_codes, [:vault_id], concurrently: true)
    create index(:oauth_refresh_tokens, [:vault_id], concurrently: true)
    create index(:users, [:plan_id], concurrently: true)

    # Redundant: identical to api_key_vaults_pkey (api_key_id, vault_id).
    drop_if_exists index(:api_key_vaults, [:api_key_id, :vault_id],
                     name: "api_key_vaults_api_key_id_vault_id_index",
                     concurrently: true
                   )
  end

  def down do
    create index(:api_key_vaults, [:api_key_id, :vault_id],
             name: "api_key_vaults_api_key_id_vault_id_index",
             unique: true,
             concurrently: true
           )

    drop index(:api_keys, [:user_id], concurrently: true)
    drop index(:api_key_vaults, [:vault_id], concurrently: true)
    drop index(:device_authorizations, [:user_id], concurrently: true)
    drop index(:device_authorizations, [:vault_id], concurrently: true)
    drop index(:device_refresh_tokens, [:vault_id], concurrently: true)
    drop index(:oauth_authorization_codes, [:vault_id], concurrently: true)
    drop index(:oauth_refresh_tokens, [:vault_id], concurrently: true)
    drop index(:users, [:plan_id], concurrently: true)
  end
end
