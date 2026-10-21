defmodule Engram.Repo.Migrations.IndexRebuildManifest do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # phase/expand. The users and vaults FK cascades on the v5 rebuild tables
  # (previous migration), and the manifest's per-vault avgdl group-by.
  # CONCURRENTLY: no write lock, the squawk-clean form.
  def change do
    create index(:rebuild_manifest, [:user_id, :vault_id], concurrently: true)
    create index(:rebuild_manifest, [:vault_id], concurrently: true)
    create index(:rebuild_manifest_vaults, [:user_id], concurrently: true)
  end
end
