defmodule Engram.Repo.Migrations.IndexLinkResolutionKeys do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Lookups by the keys added in AddLinkResolutionKeys.
  def change do
    create index(:notes, [:user_id, :vault_id, :path_ci_hmac], concurrently: true)
    create index(:attachments, [:user_id, :vault_id, :path_ci_hmac], concurrently: true)
    create index(:note_links, [:user_id, :vault_id, :target_key_hmac], concurrently: true)
  end
end
